// HeadlessQtApp: a long-running Qt 6.6.0 widgets application for Squish attachment on a
// RHEL 9 machine that has no display and on which nothing can be installed.
//
// Start it directly, e.g. with Squish:   <squish>/bin/startaut --port=4322 <share>/HeadlessQtApp/bin/HeadlessQtApp
//
// Everything it needs is found relative to the binary (no wrapper script, no environment):
//   libs/lib64/   every shared library except glibc (DT_RPATH $ORIGIN/../libs/lib64, inherited
//                 by every library loaded into the process, Squish's preloaded wrapper included)
//   plugins/      Qt platform/imageformat plugins (bin/qt.conf + QCoreApplication::addLibraryPath)
//   libs/lib64/fonts/  fonts for rendering without fontconfig (QT_QPA_FONTDIR is set here)
//   xvfb/         a virtual X server for --xvfb mode
//
// Modes:
//   (default)   QApplication on Qt's "offscreen" platform: real widgets, no X server.
//   --xvfb      starts xvfb/Xvfb on a free display, runs on the "xcb" platform against it
//               (a real X display, as Squish desktop screenshots on Linux expect) and stops
//               Xvfb again on exit.
//   --core-only plain QCoreApplication (nothing to screenshot).
//
// Logs startup, PID and screens to stdout, runs the event loop until SIGTERM or SIGINT
// (exit 0). --once exits after one event loop iteration; --screenshot <png> renders the
// window; --desktop-screenshot <png> grabs the primary QScreen the way Squish does.

#include <QApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QPixmap>
#include <QPushButton>
#include <QScreen>
#include <QSocketNotifier>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <QtGlobal>

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef HEADLESSQTAPP_VERSION
#define HEADLESSQTAPP_VERSION "0.0.0"
#endif

namespace {

// ------------------------------------------------------------------ logging
void logLine(const QString &message)
{
    const QString stamp = QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
    std::fprintf(stdout, "%s HeadlessQtApp[%lld]: %s\n", qPrintable(stamp),
                 static_cast<long long>(::getpid()), qPrintable(message));
    std::fflush(stdout);
}

// ------------------------------------------------------------------ signals
// Self-pipe (socketpair) used to forward Unix signals into the Qt event loop.
int g_signalFds[2] = {-1, -1};

void unixSignalHandler(int signum)
{
    const unsigned char byte = static_cast<unsigned char>(signum);
    const ssize_t written = ::write(g_signalFds[0], &byte, sizeof(byte)); // async-signal-safe
    (void)written;
}

bool installSignalHandlers()
{
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, g_signalFds) != 0)
        return false;
    struct sigaction action;
    std::memset(&action, 0, sizeof(action));
    action.sa_handler = unixSignalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    return ::sigaction(SIGTERM, &action, nullptr) == 0
        && ::sigaction(SIGINT, &action, nullptr) == 0;
}

const char *signalName(int signum)
{
    switch (signum) {
    case SIGTERM: return "SIGTERM";
    case SIGINT:  return "SIGINT";
    default:      return "signal";
    }
}

// ------------------------------------------------------------------ helpers
bool hasArg(int argc, char *argv[], const char *name)
{
    for (int i = 1; i < argc; ++i)
        if (std::strcmp(argv[i], name) == 0)
            return true;
    return false;
}

// Directory of the running executable, resolved without a QCoreApplication.
QString executableDir()
{
    char buf[4096];
    const ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        return QFileInfo(QString::fromLocal8Bit(buf)).absolutePath();
    }
    return QDir::currentPath();
}

// Path of the Qt Core library mapped into this process (best effort).
QString loadedQtCorePath()
{
    std::ifstream maps("/proc/self/maps"); // procfs: QFile::atEnd() is unreliable here
    std::string line;
    while (std::getline(maps, line)) {
        const std::string::size_type idx = line.find('/');
        if (idx == std::string::npos)
            continue;
        const std::string path = line.substr(idx);
        if (path.find("libQt6Core.so") != std::string::npos)
            return QString::fromLocal8Bit(path.c_str());
    }
    return QStringLiteral("(unknown)");
}

// ------------------------------------------------------------------ Xvfb (--xvfb mode)
class XvfbServer
{
public:
    ~XvfbServer() { stop(); }

    bool start(const QString &pkgDir, QString &error)
    {
        const QString xvfb = pkgDir + QStringLiteral("/xvfb/Xvfb");
        const QString xkbDir = pkgDir + QStringLiteral("/xvfb/xkb");
        if (!QFile::exists(xvfb)) {
            error = QStringLiteral("%1 does not exist").arg(xvfb);
            return false;
        }
        for (int n = 99; n < 200; ++n) {
            if (!QFile::exists(QStringLiteral("/tmp/.X11-unix/X%1").arg(n))
                && !QFile::exists(QStringLiteral("/tmp/.X%1-lock").arg(n))) {
                m_display = n;
                break;
            }
        }
        if (m_display < 0) {
            error = QStringLiteral("no free X display number between :99 and :199");
            return false;
        }
        const QByteArray display = QByteArrayLiteral(":") + QByteArray::number(m_display);
        const QByteArray screen = qEnvironmentVariableIsEmpty("HEADLESSQTAPP_XVFB_SCREEN")
            ? QByteArrayLiteral("1280x1024x24") : qgetenv("HEADLESSQTAPP_XVFB_SCREEN");
        m_logFile = QStringLiteral("/tmp/HeadlessQtApp-xvfb-%1-%2.log").arg(::getpid()).arg(m_display);

        const QByteArray xvfbPath = QFile::encodeName(xvfb);
        const QByteArray xkbPath = QFile::encodeName(xkbDir);
        const QByteArray binDir = QFile::encodeName(pkgDir + QStringLiteral("/xvfb"));
        const QByteArray logPath = QFile::encodeName(m_logFile);

        m_pid = ::fork();
        if (m_pid < 0) {
            error = QStringLiteral("fork failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
            return false;
        }
        if (m_pid == 0) {
            // child: Xvfb :N -screen 0 WxHxD -nolisten tcp -noreset -xkbdir <xkb> -fp built-ins
            // The bundled Xvfb runs "./xkbcomp" (its xkbcomp directory is patched to "."),
            // so xvfb/ must be the working directory.
            if (::chdir(binDir.constData()) != 0)
                std::_Exit(126);
            ::setenv("XKB_BINDIR", binDir.constData(), 1);
            const int fd = ::open(logPath.constData(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) { ::dup2(fd, 1); ::dup2(fd, 2); ::close(fd); }
            std::vector<const char *> args;
            const char *loader = "/lib64/ld-linux-x86-64.so.2";
            if (::access(xvfbPath.constData(), X_OK) != 0)
                args.push_back(loader); // no executable bit on the share: start via the loader
            args.push_back(xvfbPath.constData());
            args.push_back(display.constData());
            args.push_back("-screen"); args.push_back("0"); args.push_back(screen.constData());
            args.push_back("-nolisten"); args.push_back("tcp");
            args.push_back("-noreset");
            args.push_back("-xkbdir"); args.push_back(xkbPath.constData());
            args.push_back("-fp"); args.push_back("built-ins");
            args.push_back(nullptr);
            ::execv(args[0], const_cast<char *const *>(args.data()));
            std::_Exit(127);
        }
        // parent: wait for the X socket
        const QString socketPath = QStringLiteral("/tmp/.X11-unix/X%1").arg(m_display);
        for (int i = 0; i < 100; ++i) {
            if (QFile::exists(socketPath))
                break;
            int status = 0;
            if (::waitpid(m_pid, &status, WNOHANG) == m_pid) {
                m_pid = -1;
                error = QStringLiteral("Xvfb exited during startup (status %1); see %2").arg(status).arg(m_logFile);
                return false;
            }
            ::usleep(100 * 1000);
        }
        if (!QFile::exists(socketPath)) {
            error = QStringLiteral("Xvfb did not create %1 within 10 s; see %2").arg(socketPath, m_logFile);
            stop();
            return false;
        }
        qputenv("DISPLAY", display);
        if (qEnvironmentVariableIsEmpty("XKB_CONFIG_ROOT"))
            qputenv("XKB_CONFIG_ROOT", xkbPath);      // libxkbcommon in the xcb plugin
        if (qEnvironmentVariableIsEmpty("QT_XKB_CONFIG_ROOT"))
            qputenv("QT_XKB_CONFIG_ROOT", xkbPath);
        return true;
    }

    void stop()
    {
        if (m_pid > 0) {
            ::kill(m_pid, SIGTERM);
            int status = 0;
            ::waitpid(m_pid, &status, 0);
            m_pid = -1;
        }
    }

    int display() const { return m_display; }
    pid_t pid() const { return m_pid; }
    QString logFile() const { return m_logFile; }

private:
    pid_t m_pid = -1;
    int m_display = -1;
    QString m_logFile;
};

// ------------------------------------------------------------------ widgets
// A small, real widget tree for Squish to find, interact with and screenshot.
std::unique_ptr<QMainWindow> makeWindow()
{
    auto window = std::make_unique<QMainWindow>();
    window->setObjectName(QStringLiteral("mainWindow"));
    window->setWindowTitle(QStringLiteral("HeadlessQtApp"));
    window->resize(640, 400);

    auto *central = new QWidget(window.get());
    central->setObjectName(QStringLiteral("centralWidget"));
    auto *layout = new QVBoxLayout(central);

    auto *title = new QLabel(QStringLiteral("HeadlessQtApp %1 (Qt %2, pid %3)")
                                 .arg(QStringLiteral(HEADLESSQTAPP_VERSION),
                                      QString::fromLatin1(qVersion()),
                                      QString::number(::getpid())),
                             central);
    title->setObjectName(QStringLiteral("titleLabel"));
    layout->addWidget(title);

    auto *status = new QLabel(QStringLiteral("running on platform '%1', waiting for Squish")
                                  .arg(QGuiApplication::platformName()),
                              central);
    status->setObjectName(QStringLiteral("statusLabel"));
    layout->addWidget(status);

    auto *input = new QLineEdit(central);
    input->setObjectName(QStringLiteral("inputLineEdit"));
    input->setPlaceholderText(QStringLiteral("type here"));
    layout->addWidget(input);

    auto *counter = new QLabel(QStringLiteral("clicks: 0"), central);
    counter->setObjectName(QStringLiteral("counterLabel"));
    layout->addWidget(counter);

    auto *button = new QPushButton(QStringLiteral("Click me"), central);
    button->setObjectName(QStringLiteral("clickButton"));
    layout->addWidget(button);
    QObject::connect(button, &QPushButton::clicked, counter, [counter]() {
        static int clicks = 0;
        counter->setText(QStringLiteral("clicks: %1").arg(++clicks));
    });

    auto *quit = new QPushButton(QStringLiteral("Quit"), central);
    quit->setObjectName(QStringLiteral("quitButton"));
    layout->addWidget(quit);
    QObject::connect(quit, &QPushButton::clicked, []() { QCoreApplication::exit(0); });

    layout->addStretch();
    window->setCentralWidget(central);
    return window;
}

} // namespace

int main(int argc, char *argv[])
{
    const bool coreOnly = hasArg(argc, argv, "--core-only");
    const bool useXvfb = !coreOnly && hasArg(argc, argv, "--xvfb");

    // Everything is relative to <pkg>/bin/HeadlessQtApp.
    const QString pkgDir = QDir(executableDir()).absoluteFilePath(QStringLiteral(".."));
    QCoreApplication::addLibraryPath(QDir(pkgDir).absoluteFilePath(QStringLiteral("plugins")));
    if (!coreOnly && qEnvironmentVariableIsEmpty("QT_QPA_FONTDIR")) {
        const QString fontDir = QDir(pkgDir).absoluteFilePath(QStringLiteral("libs/lib64/fonts"));
        if (QDir(fontDir).exists())
            qputenv("QT_QPA_FONTDIR", QFile::encodeName(fontDir));
    }
    // Qt wants a UTF-8 locale; glibc's built-in C.UTF-8 needs no locale package.
    if (qEnvironmentVariableIsEmpty("LC_ALL") && qEnvironmentVariableIsEmpty("LANG"))
        qputenv("LANG", QByteArrayLiteral("C.UTF-8"));

    XvfbServer xvfb;
    if (useXvfb) {
        QString error;
        if (!xvfb.start(QDir(pkgDir).absolutePath(), error)) {
            std::fprintf(stderr, "HeadlessQtApp: --xvfb: %s\n", qPrintable(error));
            return 1;
        }
        if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
            qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("xcb"));
    } else if (!coreOnly && qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
        qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("offscreen"));
    }

    std::unique_ptr<QCoreApplication> app;
    if (coreOnly)
        app = std::make_unique<QCoreApplication>(argc, argv);
    else
        app = std::make_unique<QApplication>(argc, argv);

    QCoreApplication::setApplicationName(QStringLiteral("HeadlessQtApp"));
    QCoreApplication::setApplicationVersion(QStringLiteral(HEADLESSQTAPP_VERSION));
    QCoreApplication::setOrganizationName(QStringLiteral("HeadlessQtApp"));

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("Headless Qt application for Squish attachment. Runs the Qt event loop "
                       "until SIGTERM or SIGINT."));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption onceOption(QStringLiteral("once"),
        QStringLiteral("Log startup, run the event loop once and exit successfully."));
    const QCommandLineOption coreOnlyOption(QStringLiteral("core-only"),
        QStringLiteral("Run as a plain QCoreApplication (no Gui/Widgets, nothing to screenshot)."));
    const QCommandLineOption xvfbOption(QStringLiteral("xvfb"),
        QStringLiteral("Start the bundled Xvfb and run on the xcb platform against it."));
    const QCommandLineOption screenshotOption(QStringLiteral("screenshot"),
        QStringLiteral("Render the main window to <file> (PNG) and exit."), QStringLiteral("file"));
    const QCommandLineOption desktopShotOption(QStringLiteral("desktop-screenshot"),
        QStringLiteral("Grab the primary screen (QScreen::grabWindow(0), as Squish does) to <file> (PNG) and exit."),
        QStringLiteral("file"));
    parser.addOption(onceOption);
    parser.addOption(coreOnlyOption);
    parser.addOption(xvfbOption);
    parser.addOption(screenshotOption);
    parser.addOption(desktopShotOption);
    parser.process(*app);

    if (!installSignalHandlers()) {
        std::fprintf(stderr, "HeadlessQtApp: failed to install signal handlers: %s\n", std::strerror(errno));
        return 1;
    }
    // No parent: the notifier lives on the stack and must not be deleted by the application.
    QSocketNotifier notifier(g_signalFds[1], QSocketNotifier::Read);
    QObject::connect(&notifier, &QSocketNotifier::activated, app.get(), [&notifier]() {
        notifier.setEnabled(false);
        unsigned char byte = 0;
        const ssize_t n = ::read(g_signalFds[1], &byte, sizeof(byte));
        const int signum = (n == 1) ? static_cast<int>(byte) : 0;
        logLine(QStringLiteral("received %1, shutting down").arg(QLatin1String(signalName(signum))));
        QCoreApplication::exit(0);
    });

    logLine(QStringLiteral("started pid=%1 version=%2 mode=%3 exe=%4")
                .arg(::getpid())
                .arg(QStringLiteral(HEADLESSQTAPP_VERSION),
                     coreOnly ? QStringLiteral("core-only")
                              : useXvfb ? QStringLiteral("widgets/xvfb") : QStringLiteral("widgets/offscreen"),
                     QCoreApplication::applicationFilePath()));
    logLine(QStringLiteral("qt runtime=%1 built-against=%2 core-library=%3")
                .arg(QString::fromLatin1(qVersion()), QStringLiteral(QT_VERSION_STR), loadedQtCorePath()));
    if (std::strcmp(qVersion(), QT_VERSION_STR) != 0) {
        std::fprintf(stderr, "HeadlessQtApp: warning: runtime Qt %s differs from build-time Qt %s\n",
                     qVersion(), QT_VERSION_STR);
        std::fflush(stderr);
    }
    if (useXvfb)
        logLine(QStringLiteral("xvfb pid=%1 DISPLAY=:%2 log=%3").arg(xvfb.pid()).arg(xvfb.display()).arg(xvfb.logFile()));

    std::unique_ptr<QMainWindow> window;
    if (!coreOnly) {
        logLine(QStringLiteral("qpa platform=%1 plugin-paths=%2")
                    .arg(QGuiApplication::platformName(), QCoreApplication::libraryPaths().join(QLatin1Char(':'))));
        const QScreen *primary = QGuiApplication::primaryScreen();
        logLine(QStringLiteral("screens=%1 primary=%2 %3x%4")
                    .arg(QGuiApplication::screens().size())
                    .arg(primary ? primary->name() : QStringLiteral("NONE"))
                    .arg(primary ? primary->geometry().width() : 0)
                    .arg(primary ? primary->geometry().height() : 0));
        window = makeWindow();
        window->show();
        logLine(QStringLiteral("main window '%1' shown (%2x%3)")
                    .arg(window->objectName()).arg(window->width()).arg(window->height()));
    }

    if (parser.isSet(desktopShotOption) && window) {
        const QString file = parser.value(desktopShotOption);
        // Give the window a few event-loop turns to be mapped and painted.
        QTimer::singleShot(300, app.get(), [file]() {
            QScreen *screen = QGuiApplication::primaryScreen();
            if (!screen) {
                logLine(QStringLiteral("desktop screenshot FAILED: no primary QScreen"));
                QCoreApplication::exit(2);
                return;
            }
            const QPixmap pixmap = screen->grabWindow(0);
            const bool ok = !pixmap.isNull() && pixmap.save(file, "PNG");
            logLine(QStringLiteral("desktop screenshot of screen '%1' %2x%3 -> %4: %5")
                        .arg(screen->name()).arg(pixmap.width()).arg(pixmap.height())
                        .arg(file, ok ? QStringLiteral("saved") : QStringLiteral("FAILED")));
            QCoreApplication::exit(ok ? 0 : 2);
        });
    } else if (parser.isSet(desktopShotOption) || (parser.isSet(screenshotOption) && !window)) {
        std::fprintf(stderr, "HeadlessQtApp: screenshots are not available with --core-only\n");
        return 2;
    } else if (parser.isSet(screenshotOption)) {
        const QString file = parser.value(screenshotOption);
        QTimer::singleShot(0, app.get(), [&window, file]() {
            const QPixmap pixmap = window->grab();
            const bool ok = !pixmap.isNull() && pixmap.save(file, "PNG");
            logLine(QStringLiteral("screenshot %1x%2 -> %3: %4")
                        .arg(pixmap.width()).arg(pixmap.height())
                        .arg(file, ok ? QStringLiteral("saved") : QStringLiteral("FAILED")));
            QCoreApplication::exit(ok ? 0 : 2);
        });
    } else if (parser.isSet(onceOption)) {
        logLine(QStringLiteral("--once given: exiting after one event loop iteration"));
        QTimer::singleShot(0, app.get(), []() { QCoreApplication::exit(0); });
    } else {
        logLine(QStringLiteral("running event loop until SIGTERM or SIGINT"));
    }

    const int rc = app->exec();
    logLine(QStringLiteral("exiting with status %1").arg(rc));
    window.reset();
    app.reset();
    xvfb.stop();
    ::close(g_signalFds[0]);
    ::close(g_signalFds[1]);
    return rc;
}
