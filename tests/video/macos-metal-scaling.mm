// Execute the production video sampler on Metal, against an independent CPU
// area integral. No window, host connection, screen capture or TCC permission.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

struct Vertex { simd_float4 position; simd_float2 uv; };
struct Extent { int w, h; };
struct Crop { float x = 0, y = 0, w = 1, h = 1; };

static void require(bool ok, const char* message)
{
    if (!ok) throw std::runtime_error(message);
}

struct Image {
    Extent size;
    int channels, depth;
    bool high;
    std::vector<uint16_t> values;

    Image(Extent s, int c, int d, bool hi, int pattern) :
        size(s), channels(c), depth(d), high(hi), values(s.w*s.h*c)
    {
        const int maximum = (1 << depth) - 1;
        for (int y = 0; y < s.h; ++y) for (int x = 0; x < s.w; ++x)
            for (int channel = 0; channel < c; ++channel) {
                int value;
                switch (pattern) {
                case 0: value = ((x + y + channel) & 1) * maximum; break;
                case 1: value = (x % 4 == channel || y % 7 == channel) ? maximum : 0; break;
                case 2: value = (x*31 + y*13 + channel*101) % (maximum + 1); break;
                case 4: value = (x/4 + channel*101) % (maximum + 1); break;
                case 5: value = (x/16 + channel*101) % (maximum + 1); break;
                default: value = maximum / 3; break;
                }
                values[(y*s.w + x)*c + channel] = value << (high ? 6 : 0);
            }
    }

    double pixel(int x, int y, int channel) const
    {
        x = std::clamp(x, 0, size.w - 1);
        y = std::clamp(y, 0, size.h - 1);
        return values[(y*size.w + x)*channels + channel] / (depth == 8 ? 255.0 : 65535.0);
    }

    double integral(double u, double v, double sx, double sy, int channel) const
    {
        // One texel-wide box equals bilinear reconstruction on an unshrunk axis.
        sx = std::max(1.0, sx); sy = std::max(1.0, sy);
        const double left = u*size.w - sx/2, right = left + sx;
        const double top = v*size.h - sy/2, bottom = top + sy;
        double result = 0;
        for (int y = int(std::floor(top)); y < int(std::ceil(bottom)); ++y)
            for (int x = int(std::floor(left)); x < int(std::ceil(right)); ++x) {
                const double wx = std::max(0.0, std::min(right, x+1.0) - std::max(left, double(x)));
                const double wy = std::max(0.0, std::min(bottom, y+1.0) - std::max(top, double(y)));
                result += pixel(x, y, channel)*wx*wy;
            }
        return result/(sx*sy);
    }
};

class Probe {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> area, linear;
    id<MTLComputePipelineState> horizontal;
public:
    Probe(id<MTLDevice> d, NSString* source) : device(d), queue([d newCommandQueue])
    {
        // Both entrypoints use the actual production Vertex and sampler. The
        // baseline also demonstrates that missing thin lines fail this fixture.
        source = [source stringByAppendingString:@"\n"
            "fragment float4 test_area(Vertex v [[stage_in]], texture2d<float> t [[texture(0)]]) { return sampleVideoPlane(t, v.texCoords); }\n"
            "fragment float4 test_linear(Vertex v [[stage_in]], texture2d<float> t [[texture(0)]]) { return t.sample(s, v.texCoords); }\n"];
        NSError* error = nil;
        auto library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { NSLog(@"%@", error); throw std::runtime_error("production shader compilation failed"); }
        auto desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"vs_draw"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        desc.fragmentFunction = [library newFunctionWithName:@"test_area"];
        area = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        desc.fragmentFunction = [library newFunctionWithName:@"test_linear"];
        linear = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        horizontal = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"cs_reduce_horizontal"] error:&error];
        require(area && linear && horizontal && queue, "Metal pipeline initialization");
    }

    std::vector<float> render(const Image& image, Extent output, Crop crop, bool baseline,
                              double* gpuMs = nullptr)
    { @autoreleasepool {
        const auto format = image.depth == 8 ?
            (image.channels == 1 ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm) :
            (image.channels == 1 ? MTLPixelFormatR16Unorm : MTLPixelFormatRG16Unorm);
        auto td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
            width:image.size.w height:image.size.h mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        auto input = [device newTextureWithDescriptor:td];
        require(input != nil, "input allocation");
        std::vector<uint8_t> bytes(image.values.begin(), image.values.end());
        [input replaceRegion:MTLRegionMake2D(0, 0, image.size.w, image.size.h) mipmapLevel:0
            withBytes:image.depth == 8 ? (const void*)bytes.data() : (const void*)image.values.data()
            bytesPerRow:image.size.w*image.channels*(image.depth == 8 ? 1 : 2)];
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
            width:output.w height:output.h mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        auto target = [device newTextureWithDescriptor:td];
        require(target != nil, "output allocation");
        auto command = [queue commandBuffer];
        // Match the renderer's bounded-work path; still compare against a
        // single independent area integral, not against this two-pass code.
        if (!baseline && image.size.w*crop.w > 8.0*output.w) {
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                width:output.w height:image.size.h mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            auto reduced = [device newTextureWithDescriptor:descriptor];
            require(reduced != nil, "horizontal intermediate allocation");
            auto compute = [command computeCommandEncoder];
            const simd_float2 bounds = {crop.x, crop.x+crop.w};
            [compute setComputePipelineState:horizontal];
            [compute setTexture:input atIndex:0];
            [compute setTexture:reduced atIndex:1];
            [compute setBytes:&bounds length:sizeof(bounds) atIndex:0];
            [compute dispatchThreads:MTLSizeMake(output.w,image.size.h,1)
                threadsPerThreadgroup:MTLSizeMake(horizontal.threadExecutionWidth,1,1)];
            [compute endEncoding];
            input = reduced;
            crop.x = 0; crop.w = 1;
        }
        Vertex vertices[] = {
            {{-1, 1,0,1},{crop.x,crop.y}}, {{-1,-1,0,1},{crop.x,crop.y+crop.h}},
            {{ 1, 1,0,1},{crop.x+crop.w,crop.y}}, {{1,-1,0,1},{crop.x+crop.w,crop.y+crop.h}}
        };
        auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        auto encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:baseline ? linear : area];
        [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
        [encoder setFragmentTexture:input atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            NSLog(@"%@", command.error);
            throw std::runtime_error("GPU command failed");
        }
        if (gpuMs) *gpuMs = (command.GPUEndTime - command.GPUStartTime)*1000;
        std::vector<float> result(output.w*output.h*4);
        [target getBytes:result.data() bytesPerRow:output.w*4*sizeof(float)
            fromRegion:MTLRegionMake2D(0,0,output.w,output.h) mipmapLevel:0];
        return result;
    }}

    void check(const Image& image, Extent output, Crop crop = {}, double tolerance = -1)
    {
        const auto actual = render(image, output, crop, false);
        const bool unchanged = image.size.w*crop.w <= output.w && image.size.h*crop.h <= output.h;
        const auto baseline = unchanged ? render(image, output, crop, true) : std::vector<float>();
        double worst = 0;
        // Linear texture weights have finite subtexel precision. This bounds
        // that interpolation error without permitting an 8-bit conversion of
        // low-aligned 10-bit samples (whose normalized range is only 0..1023/65535).
        if (tolerance < 0) tolerance = image.depth == 10 && !image.high ? 4.0/65535 : 4.0/1023;
        for (int y = 0; y < output.h; ++y) for (int x = 0; x < output.w; ++x)
            for (int c = 0; c < image.channels; ++c) {
                const double u = crop.x + (x+0.5)*crop.w/output.w;
                const double v = crop.y + (y+0.5)*crop.h/output.h;
                const double expected = image.integral(u, v, image.size.w*double(crop.w)/output.w,
                    image.size.h*double(crop.h)/output.h, c);
                const size_t index = (y*output.w+x)*4+c;
                const double error = std::abs(actual[index] - expected);
                worst = std::max(worst, error);
                require(std::isfinite(actual[index]), "non-finite filtered pixel");
                if (error > tolerance) {
                    std::fprintf(stderr, "FAIL %dx%d->%dx%d depth=%d high=%d channels=%d x=%d y=%d c=%d actual=%.9f expected=%.9f error=%.9f\n",
                        image.size.w,image.size.h,output.w,output.h,image.depth,image.high,image.channels,
                        x,y,c,actual[index],expected,error);
                    throw std::runtime_error("area reference mismatch");
                }
                if (unchanged) require(actual[index] == baseline[index], "1:1/upscale path changed");
            }
        std::printf("PASS %dx%d->%dx%d depth=%d high=%d channels=%d worst=%.8f unchanged=%d\n",
            image.size.w,image.size.h,output.w,output.h,image.depth,image.high,image.channels,worst,unchanged);
    }

    void benchmark()
    {
        Image image({5120,2160}, 2, 10, true, 1);
        for (Extent size : {Extent{2560,1080}, {1710,721}, {1280,540}, {320,135}, {32,14}, {1,1}}) {
            for (bool baseline : {true, false}) {
                std::vector<double> timings;
                for (int i = 0; i < 6; ++i) {
                    double ms;
                    render(image, size, {}, baseline, &ms);
                    if (i) timings.push_back(ms);
                }
                std::sort(timings.begin(), timings.end());
                std::printf("GPU plane=RG16Unorm 5120x2160->%dx%d filter=%s median_ms=%.3f max_ms=%.3f\n",
                    size.w,size.h,baseline ? "linear" : "area",timings[2],timings.back());
                std::fflush(stdout);
            }
        }
    }
};

int main(int argc, char** argv)
{
    @autoreleasepool {
        if (argc < 2 || argc > 3) return 2;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { std::fprintf(stderr, "SKIP: no Metal GPU; scaling is not GPU-qualified\n"); return 77; }
        NSError* error = nil;
        NSString* source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        if (!source) { NSLog(@"%@", error); return 2; }
        try {
            Probe probe(device, source);
            for (int channels : {1,2}) for (int depth : {8,10}) for (bool high : {false,true}) {
                if (depth == 8 && high) continue;
                for (int pattern = 0; pattern < 4; ++pattern) {
                    for (Extent output : {Extent{63,37}, {126,74}, {31,18}, {23,17}, {7,5}, {1,1}, {7,74}}) {
                        @autoreleasepool { probe.check(Image({63,37}, channels, depth, high, pattern), output); }
                    }
                    @autoreleasepool { probe.check(Image({513,257}, channels, depth, high, pattern), {127,93}, {.125f,.25f,.625f,.5f}); }
                    @autoreleasepool { probe.check(Image({513,257}, channels, depth, high, pattern), {17,11}, {.125f,.25f,.625f,.5f}); }
                }
            }
            // Regression witness: original bilinear misses these one-pixel lines.
            // Four identical source pixels per code also require every 10-bit
            // level to survive reduction; the discontinuity tolerance above
            // must not hide a precision downgrade to 8-bit intermediates.
            for (bool high : {false,true}) {
                probe.check(Image({4096,4}, 2, 10, high, 4), {1024,1}, {},
                    high ? 0.1*64/65535 : 0.1/65535);
                probe.check(Image({16384,4}, 2, 10, high, 5), {1024,1}, {},
                    high ? 0.45*64/65535 : 0.45/65535);
            }
            Image thin({64,32}, 1, 10, true, 1);
            const auto old = probe.render(thin, {16,8}, {}, true);
            const auto fixed = probe.render(thin, {16,8}, {}, false);
            require(std::abs(old[0] - fixed[0]) > .1f, "fixture must distinguish old sampling");
            if (argc == 3 && std::string(argv[2]) == "--benchmark") probe.benchmark();
            std::puts("PASS production Metal area sampler; 1:1/upscale, fractional/cropped/anisotropic reduction, 8/10-bit R/RG planes");
        } catch (const std::exception& e) {
            std::fprintf(stderr, "FAIL: %s\n", e.what()); return 1;
        }
    }
}
