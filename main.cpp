// HeadlessQtApp: minimal Qt anchor process for Squish. It creates no window.
//
// It connects to this machine's own X display (DISPLAY, default ":0") through Qt's xcb
// platform plugin, so that once Squish is attached (startaut) its desktop screenshots show
// whatever is on that display, and image-based interaction works on it.
//
//   <squish>/bin/startaut --port=4322 /path/to/HeadlessQtApp/bin/HeadlessQtApp
//
// Overrides: DISPLAY=:N (which display), XAUTHORITY=<cookie file> (if the X server needs
// one), QT_QPA_PLATFORM=offscreen (run with no display at all; nothing to screenshot then).
// Everything else (Qt libraries, plugins) is found relative to the binary.

#include <QGuiApplication>
#include <QScreen>

#include <cstdio>
#include <unistd.h>

int main(int argc, char *argv[])
{
    if (qEnvironmentVariableIsEmpty("DISPLAY"))
        qputenv("DISPLAY", QByteArrayLiteral(":0"));
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("xcb"));
    if (qEnvironmentVariableIsEmpty("LC_ALL") && qEnvironmentVariableIsEmpty("LANG"))
        qputenv("LANG", QByteArrayLiteral("C.UTF-8")); // Qt wants UTF-8; glibc has this built in

    QGuiApplication app(argc, argv);

    const QScreen *screen = QGuiApplication::primaryScreen();
    std::printf("HeadlessQtApp pid=%ld qt=%s platform=%s display=%s screen=%s %dx%d\n",
                static_cast<long>(::getpid()), qVersion(),
                qPrintable(QGuiApplication::platformName()), qgetenv("DISPLAY").constData(),
                screen ? qPrintable(screen->name()) : "none",
                screen ? screen->geometry().width() : 0,
                screen ? screen->geometry().height() : 0);
    std::fflush(stdout);

    return app.exec();
}
