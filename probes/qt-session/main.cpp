#include "sessionwindow.h"
#include "sessionshell.h"
#include "precisioncheck.h"
#include "videoprecisioncheck.h"
#include "presentercheck.h"

#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQuickStyle>
#include <QScreen>
#include <QScopeGuard>
#include <QShortcut>
#include <QTimer>
#include <fontconfig/fontconfig.h>

#include <memory>

int main(int argc, char** argv)
{
    // Release Material's process-wide font cache after Qt/application teardown,
    // including early probe exits, without suppressing sanitizer leak checks.
    const auto fontconfigCleanup = qScopeGuard([] { FcFini(); });
    // Use the same style as the real Client, including its geometry defaults.
    qputenv("QT_QUICK_CONTROLS_MATERIAL_THEME", "Dark");
    qputenv("QT_QUICK_CONTROLS_MATERIAL_VARIANT", "Dense");
    qputenv("QT_QUICK_CONTROLS_MATERIAL_ACCENT", "#5A9CE6");
    QQuickStyle::setStyle(QStringLiteral("Material"));
    qputenv("QSG_RENDER_LOOP", "basic"); // match the actual Client
    QtSessionShell::configureWaylandExposure();
    QGuiApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("PLANK Qt session probe"));
    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral(
        "Isolated Ubuntu Qt surface/input qualification. No network, credentials or tablet forwarding.\n"
        "Hover at the top for 1 second; unpinned toolbar hides after 5 seconds away.\n"
        "F8 simulates Host unavailability, F11 toggles fullscreen; Escape exits."));
    parser.addHelpOption();
    parser.addOption({QStringLiteral("fullscreen"), QStringLiteral("Start fullscreen on the selected output")});
    parser.addOption({QStringLiteral("screen"), QStringLiteral("Output index (0-based)"), QStringLiteral("index"), QStringLiteral("0")});
    parser.addOption({QStringLiteral("quit-after"), QStringLiteral("Exit after this many seconds (0 disables)"), QStringLiteral("seconds"), QStringLiteral("0")});
    parser.addOption({QStringLiteral("precision-check"), QStringLiteral("Require and test an actual 10-bit OpenGL framebuffer; exits with pass/fail")});
    parser.addOption({QStringLiteral("video-precision-check"), QStringLiteral("Exercise the real video shader with exact packed GPU textures (not hardware decoding)")});
    parser.addOption({QStringLiteral("presenter-lifecycle-check"), QStringLiteral("Repeat actual VA-API decode/draw/swap qualification; requires a hardware render device")});
    parser.addOption({QStringLiteral("with-audio"), QStringLiteral("Open and retire silent native PipeWire playback during presenter qualification")});
    parser.addOption({QStringLiteral("native-child"), QStringLiteral("Put the Qt surface inside a normally decorated Qt raster shell")});
    parser.addOption({QStringLiteral("roundtrip"), QStringLiteral("Qualification only: toggle fullscreen/windowed four times before the precision check")});
    parser.addOption({QStringLiteral("snapshot"), QStringLiteral("Save the synthetic toolbar UI for review (not a precision test)"), QStringLiteral("path")});
    parser.process(app);
    bool validScreen = false, validTimeout = false;
    const int screen = parser.value("screen").toInt(&validScreen);
    const int timeout = parser.value("quit-after").toInt(&validTimeout);
    if (!validScreen || screen < 0 || screen >= app.screens().size() ||
            !validTimeout || timeout < 0 || timeout > 3600 ||
            (parser.isSet("with-audio") && !parser.isSet("presenter-lifecycle-check")) ||
            (parser.isSet("presenter-lifecycle-check") &&
             (parser.isSet("precision-check") || parser.isSet("video-precision-check") ||
              parser.isSet("roundtrip") || timeout)) ||
            (parser.isSet("roundtrip") && !parser.isSet("precision-check") && !parser.isSet("video-precision-check")) ||
            (parser.isSet("precision-check") && parser.isSet("video-precision-check"))) {
        qCritical("Invalid screen/timeout, or roundtrip used without precision-check");
        return 2;
    }
    if (parser.isSet("precision-check") || parser.isSet("video-precision-check") || parser.isSet("presenter-lifecycle-check"))
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    std::unique_ptr<QtSessionShell> shell;
    std::unique_ptr<QtSessionWindow> standalone;
    if (parser.isSet("native-child")) shell = std::make_unique<QtSessionShell>();
    else standalone = std::make_unique<QtSessionWindow>();
    QtSessionWindow& window = shell ? shell->surface() : *standalone;
    if (window.status() != QQuickView::Ready) return 1;
    QWindow* topLevel = shell ? static_cast<QWindow*>(shell.get()) : &window;
    topLevel->setScreen(app.screens().at(screen));
    // This is an illustrative letterboxed *test* canvas, not a negotiated
    // stream or a second production aspect-fit implementation.
    const auto updateGeometry = [&window] {
        const QSize pixels(qRound(window.width() * window.devicePixelRatio()),
                           qRound(window.height() * window.devicePixelRatio()));
        const QSize remote(5120, 2160);
        const QSize fitted = remote.scaled(pixels, Qt::KeepAspectRatio);
        window.setPresentation({remote, {QPointF(), remote},
            {QPointF((pixels.width() - fitted.width()) / 2.0,
                     (pixels.height() - fitted.height()) / 2.0), fitted}, pixels, window.size()});
    };
    QObject::connect(&window, &QtSessionWindow::surfaceSizeChanged, &window, updateGeometry);
    QObject::connect(&window, &QtSessionWindow::disconnectRequested, &app, &QGuiApplication::quit);
    // Probe shortcuts only, not a proposed set of production hotkeys. Do not
    // enable remote-key interception, which would correctly suppress shortcuts.
    QShortcut quit(QKeySequence(Qt::Key_Escape), &window);
    QObject::connect(&quit, &QShortcut::activated, &app, &QGuiApplication::quit);
    QShortcut fullscreen(QKeySequence(Qt::Key_F11), &window);
    QObject::connect(&fullscreen, &QShortcut::activated, &window, &QtSessionWindow::toggleFullscreen);
    QShortcut waiting(QKeySequence(Qt::Key_F8), &window);
    QObject::connect(&waiting, &QShortcut::activated, &window, [&window] { window.setWaiting(!window.waiting()); });
    topLevel->resize(1280, 720);
    if (parser.isSet("snapshot")) {
        window.setPinned(true);
        QTimer::singleShot(1000, &window, [&window, &parser] {
            if (!window.grabWindow().save(parser.value("snapshot"))) {
                qWarning("Could not save the synthetic UI snapshot");
                QCoreApplication::exit(1);
            }
        });
    }
    if (parser.isSet("precision-check")) runQtFramebufferPrecisionCheck(window);
    if (parser.isSet("video-precision-check")) runQtVideoPrecisionCheck(window);
    if (parser.isSet("presenter-lifecycle-check")) runQtPresenterLifecycleCheck(window, parser.isSet("with-audio"));
    if (parser.isSet("fullscreen")) topLevel->showFullScreen();
    else topLevel->show();
    if (parser.isSet("roundtrip")) {
        for (int step = 1; step <= 4; ++step)
            QTimer::singleShot(step * 300, &window, &QtSessionWindow::toggleFullscreen);
    }
    updateGeometry();
    if (timeout && !parser.isSet("precision-check") && !parser.isSet("video-precision-check"))
        QTimer::singleShot(timeout * 1000, &app, &QGuiApplication::quit);
    return app.exec();
}
