// SPDX-License-Identifier: GPL-3.0-or-later
// Package the selected approved artwork as a standard macOS iconset, preserving
// its aspect ratio and transparency. Do not add another inset or circular mask.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSURL *input = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *output = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)input, NULL);
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
        if (source) CFRelease(source);
        if (!image) return 1;
        CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSArray *sizes = @[@16, @32, @128, @256, @512];
        BOOL success = colors != NULL;
        for (NSNumber *base in sizes) {
            for (unsigned scale = 1; success && scale <= 2; scale++) {
                size_t pixels = base.unsignedIntegerValue * scale;
                CGContextRef bitmap = CGBitmapContextCreate(NULL, pixels, pixels, 8, pixels * 4, colors,
                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
                if (!bitmap) { success = NO; break; }
                double factor = MIN((double)pixels / CGImageGetWidth(image), (double)pixels / CGImageGetHeight(image));
                double width = CGImageGetWidth(image) * factor, height = CGImageGetHeight(image) * factor;
                CGContextClearRect(bitmap, CGRectMake(0, 0, pixels, pixels));
                CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
                CGContextDrawImage(bitmap, CGRectMake((pixels - width) / 2, (pixels - height) / 2, width, height), image);
                CGImageRef result = CGBitmapContextCreateImage(bitmap);
                NSString *name = [NSString stringWithFormat:@"icon_%@x%@%@.png", base, base, scale == 2 ? @"@2x" : @""];
                NSURL *path = [output URLByAppendingPathComponent:name];
                CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)path, CFSTR("public.png"), 1, NULL);
                if (result && destination) {
                    CGImageDestinationAddImage(destination, result, NULL);
                    success = CGImageDestinationFinalize(destination);
                } else success = NO;
                if (destination) CFRelease(destination);
                if (result) CFRelease(result);
                CGContextRelease(bitmap);
            }
        }
        if (colors) CGColorSpaceRelease(colors);
        CGImageRelease(image);
        return success ? 0 : 1;
    }
}
