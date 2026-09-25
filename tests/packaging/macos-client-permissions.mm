// Actual permission model and QML layout with only OS boundaries replaced.
// No real consent, System Settings, capture, session or HID device is opened.
#include <QGuiApplication>
#include <QDesktopServices>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QQuickItem>
#include <QTimer>
#include <QImage>
#include <QDir>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include "../../apps/client/app/backend/macpermissions.h"
#include "../../apps/client/app/cli/commandlineparser.h"
#include "../../apps/client/app/streaming/input/macrawwacom.h"
#include <cassert>

static bool accessAllowed, inputAllowed, canConfigure = true;
static int micPermission, tabletPresence;
static unsigned requests, settingsOpened;
static bool settingsSuccess = true;
static std::function<void()> micReply;
static Boolean testAccessibility() { return accessAllowed; }
static IOHIDAccessType testInput(IOHIDRequestType type) {
    assert(type == kIOHIDRequestTypeListenEvent);
    return inputAllowed ? kIOHIDAccessTypeGranted : kIOHIDAccessTypeDenied;
}
int plankMacMicrophonePermission() { return micPermission; }
void plankMacRequestMicrophonePermission(std::function<void()> completed) { ++requests; micReply = completed; }
int MacRawWacomInput::supportedTabletPresence() { return tabletPresence; }
void MacRawWacomInput::requestPermissionIfNeeded() { ++requests; }
class TestDesktopServices {
public:
    static bool openUrl(const QUrl& url) {
        assert(url.scheme() == "x-apple.systempreferences");
        assert(url.toString().contains("Privacy_"));
        ++settingsOpened; return settingsSuccess;
    }
};
#define AXIsProcessTrusted testAccessibility
#define IOHIDCheckAccess testInput
#define QDesktopServices TestDesktopServices
#include "../../apps/client/app/backend/macpermissions.mm"
#undef QDesktopServices

static QQuickItem* findItem(QQuickItem* root, const QString& name)
{
    if (root->objectName() == name) return root;
    for (auto child : root->childItems())
        if (auto found = findItem(child, name)) return found;
    return nullptr;
}

int main(int argc, char** argv)
{
    QGuiApplication app(argc, argv);
    app.setApplicationVersion("1.1.021-test");
    app.setQuitOnLastWindowClosed(false); // Verify setup close before ending the fixture.
    GlobalCommandLineParser parser;
    if (argc == 2 && QByteArray(argv[1]) == "--test-invalid-setup") {
        parser.parse({"plank-client", "--setup-permissions", "stream", "example.invalid"});
        return 99; // The real parser must reject combining setup and streaming.
    }
    assert(parser.parse({"plank-client"}) == GlobalCommandLineParser::NormalStartRequested);
    assert(parser.parse({"plank-client", "stream", "example.invalid"}) == GlobalCommandLineParser::StreamRequested);
    assert(parser.parse({"plank-client", "--setup-permissions"}) == GlobalCommandLineParser::PermissionsSetupRequested);
    MacPermissions permissions([] { return canConfigure; });
    auto row = [&](int i) { return permissions.rows().at(i).toMap(); };
    permissions.refresh();
    assert(permissions.rows().size() == 3 && requests == 0 && settingsOpened == 0);
    assert(!row(0)["verified"].toBool());
    assert(row(1)["status"].toString() == "Not requested");
    assert(!row(2)["actionable"].toBool());
    tabletPresence = -1; permissions.refresh();
    assert(row(2)["status"].toString() == "Could not check tablet");
    tabletPresence = 1; permissions.refresh(); assert(row(2)["actionable"].toBool());
    canConfigure = false;
    for (int i = 0; i < 3; ++i) permissions.request(i);
    assert(requests == 0 && settingsOpened == 0 && !permissions.error().isEmpty());
    canConfigure = true;
    permissions.request(-1); permissions.request(3); assert(settingsOpened == 0);
    permissions.request(1); permissions.request(1); assert(requests == 1);
    micPermission = -1; micReply();
    assert(row(1)["status"].toString() == "Not allowed");
    permissions.request(1); assert(settingsOpened == 1);
    settingsSuccess = false; permissions.request(0); assert(!permissions.error().isEmpty());
    settingsSuccess = true; permissions.request(0); assert(permissions.error().isEmpty());
    permissions.request(2); assert(requests == 2);
    micPermission = 0;
    auto temporary = new MacPermissions([] { return true; });
    temporary->request(1); delete temporary; micReply(); // Guard late native completion.
    micPermission = 1; accessAllowed = inputAllowed = true;
    permissions.refresh();
    for (int i = 0; i < 3; ++i) assert(row(i)["verified"].toBool());
    assert(requests == 3);

    assert(argc >= 2);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("macPermissions", &permissions);
    const QUrl source = QUrl::fromLocalFile(QDir(QString::fromLocal8Bit(argv[1])).absolutePath() + "/");
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app, [](const QList<QQmlError>& errors) {
        for (const auto& error : errors) qCritical() << error;
        std::abort();
    });
    const bool dialogMode = argc == 4 && QByteArray(argv[3]) == "--dialog";
    if (dialogMode) {
        engine.loadData("import QtQuick\nimport QtQuick.Controls\n"
            "ApplicationWindow { width: 720; height: 680; visible: true; "
            "Loader { source: 'MacPermissionsDialog.qml'; onLoaded: item.open() } }",
            source.resolved(QUrl("PermissionTest.qml")));
    } else {
        engine.load(source.resolved(QUrl("MacPermissionSetup.qml")));
    }
    assert(engine.rootObjects().size() == 1);
    QTimer::singleShot(500, &app, [&] {
        auto window = qobject_cast<QQuickWindow*>(engine.rootObjects().first());
        auto pane = window->findChild<QQuickItem*>("permissions");
        assert(pane && pane->isVisible());
        assert(pane->width() <= window->width());
        assert(pane->height() > 200 && pane->height() < window->height());
        auto close = window->findChild<QQuickItem*>("closeButton");
        auto refresh = window->findChild<QQuickItem*>("refreshButton");
        assert(close && refresh);
        const QPointF closePosition = close->mapToScene(QPointF(0, 0));
        const QPointF refreshPosition = refresh->mapToScene(QPointF(0, 0));
        if (!dialogMode) {
            assert(qAbs(closePosition.x() + close->width() - (window->width() - 24)) < 1);
            assert(refreshPosition.x() > window->width() / 2);
        }
        assert(qAbs(closePosition.y() - refreshPosition.y()) < 1);
        // A long unavailable status must remain inside its own grid column.
        accessAllowed = inputAllowed = false; micPermission = -1; tabletPresence = 0;
        permissions.refresh();
        // Let the new Repeater delegates complete the next layout/render pass.
        QTimer::singleShot(100, &app, [&, window, close] {
            if (argc >= 3) assert(window->grabWindow().save(QString::fromLocal8Bit(argv[2])));
            auto status = findItem(window->contentItem(), "permissionStatus2");
            assert(status && status->property("text").toString().contains("No supported tablet"));
            assert(status->property("contentHeight").toReal() <= status->height());
            assert(QMetaObject::invokeMethod(close, "clicked"));
            QTimer::singleShot(300, &app, [&, window] {
                assert(window->isVisible() == dialogMode);
                if (dialogMode) {
                    auto dialog = window->findChild<QObject*>("permissionsDialog");
                    assert(dialog && !dialog->property("opened").toBool());
                }
                puts("Client permissions: denied/unknown/granted/absent, active-stream guard, late callback, setup parser, QML layout and close passed");
                app.quit();
            });
        });
    });
    return app.exec();
}
