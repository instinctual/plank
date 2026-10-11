#include "sessionwindow.h"
#include "precisioncheck.h"

#include <QCommandLineParser>
#include <QGuiApplication>
#include <QScreen>
#include <QShortcut>
#include <QTimer>

int main(int argc, char** argv)
{
    QGuiApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("PLANK Qt session probe"));
    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral(
        "Isolated Ubuntu Qt surface/input qualification. No network, credentials, audio or tablet forwarding.\n"
        "Hover at the top for 1 second; unpinned toolbar hides after 5 seconds away.\n"
        "F8 simulates Host unavailability, F11 toggles fullscreen; Escape exits."));
    parser.addHelpOption();
    parser.addOption({QStringLiteral("fullscreen"), QStringLiteral("Start fullscreen on the selected output")});
    parser.addOption({QStringLiteral("screen"), QStringLiteral("Output index (0-based)"), QStringLiteral("index"), QStringLiteral("0")});
    parser.addOption({QStringLiteral("quit-after"), QStringLiteral("Exit after this many seconds (0 disables)"), QStringLiteral("seconds"), QStringLiteral("0")});
    parser.addOption({QStringLiteral("precision-check"), QStringLiteral("Require and test an actual 10-bit OpenGL framebuffer; exits with pass/fail")});
    parser.addOption({QStringLiteral("snapshot"), QStringLiteral("Save the synthetic toolbar UI for review (not a precision test)"), QStringLiteral("path")});
    parser.process(app);
    bool validScreen = false, validTimeout = false;
    const int screen = parser.value("screen").toInt(&validScreen);
    const int timeout = parser.value("quit-after").toInt(&validTimeout);
    if (!validScreen || screen < 0 || screen >= app.screens().size() ||
            !validTimeout || timeout < 0 || timeout > 3600) {
        qCritical("Invalid screen or timeout argument");
        return 2;
    }
    if (parser.isSet("precision-check")) QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    QtSessionWindow window;
    if (window.status() != QQuickView::Ready) return 1;
    window.setScreen(app.screens().at(screen));
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
    QObject::connect(&window, &QtSessionWindow::keepWaitingRequested, &window, [&window] { window.setWaiting(false); });
    // Probe shortcuts only, not a proposed set of production hotkeys. Do not
    // enable remote-key interception, which would correctly suppress shortcuts.
    QShortcut quit(QKeySequence(Qt::Key_Escape), &window);
    QObject::connect(&quit, &QShortcut::activated, &app, &QGuiApplication::quit);
    QShortcut fullscreen(QKeySequence(Qt::Key_F11), &window);
    QObject::connect(&fullscreen, &QShortcut::activated, &window, &QtSessionWindow::toggleFullscreen);
    QShortcut waiting(QKeySequence(Qt::Key_F8), &window);
    QObject::connect(&waiting, &QShortcut::activated, &window, [&window] { window.setWaiting(!window.waiting()); });
    window.resize(1280, 720);
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
    if (parser.isSet("fullscreen")) window.showFullScreen();
    else window.show();
    updateGeometry();
    if (timeout && !parser.isSet("precision-check")) QTimer::singleShot(timeout * 1000, &app, &QGuiApplication::quit);
    return app.exec();
}
