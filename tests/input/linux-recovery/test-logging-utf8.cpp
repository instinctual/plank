// Exercise the actual narrow Boost.Log/file path under the minimal C locale.
#include "src/logging.h"
#include <gtest/gtest.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <locale>
#include <cstdlib>

TEST(HostLogging, Utf8MessageAndFilenameDoNotNeedAWideLocaleFacet) {
    struct LocaleGuard {
        std::locale previous = std::locale();
        ~LocaleGuard() { std::locale::global(previous); }
    } locale;
    std::locale::global(std::locale::classic());
    std::string pattern = (std::filesystem::temp_directory_path() / "plank-log-test-XXXXXX").string();
    ASSERT_NE(mkdtemp(pattern.data()), nullptr);
    struct DirectoryGuard {
        std::filesystem::path path;
        ~DirectoryGuard() { std::filesystem::remove_all(path); }
    } directory {pattern};
    const auto path = directory.path / "日本語-é.log";
    const std::string message = "PLANK café — 日本語 🖥";
    {
        auto logger = logging::init(2, path.string());
        ASSERT_NE(logger, nullptr);
        BOOST_LOG(info) << message;
        logging::log_flush();
    }
    std::ifstream input(path, std::ios::binary);
    const std::string bytes {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
    EXPECT_NE(bytes.find(message), std::string::npos);
    EXPECT_EQ(logging::bracket(message), "[" + message + "]");
}
