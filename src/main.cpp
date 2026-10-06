// headlessQtApp: a long-running Qt application for Squish attachment on a machine without
// a display.
//
// - QApplication on Qt's "offscreen" platform plugin: real QWidgets exist and can be
//   inspected and screenshotted by Squish, but nothing is ever shown on a screen and no
//   X11/Wayland/OpenGL is needed. The platform is forced to "offscreen" unless
//   QT_QPA_PLATFORM is already set.
// - "--core-only": run as a plain QCoreApplication (no Gui/Widgets/QPA at all).
// - Logs its startup and PID to standard output, then runs the event loop until SIGTERM or
//   SIGINT (exit status 0). "--once": logs startup, spins the event loop once, exits 0.

#include <QCoreApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSocketNotifier>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QtGlobal>

#include <QApplication>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QPixmap>
#include <QScreen>
#include <QPushButton>
#include <QVBoxLayout>
#include <QWidget>

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>

#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef HEADLESSQTAPP_VERSION
#define HEADLESSQTAPP_VERSION "0.0.0"
#endif

namespace {

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

void logLine(const QString &message)
{
    const QString stamp = QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
    std::fprintf(stdout, "%s headlessQtApp[%lld]: %s\n", qPrintable(stamp),
                 static_cast<long long>(QCoreApplication::applicationPid()), qPrintable(message));
    std::fflush(stdout);
}

// Path of the Qt Core library mapped into this process (best effort, Linux only).
QString loadedQtCorePath()
{
#ifdef Q_OS_LINUX
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
#endif
    return QStringLiteral("(unknown)");
}

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
#ifdef Q_OS_LINUX
    char buf[4096];
    const ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        return QFileInfo(QString::fromLocal8Bit(buf)).absolutePath();
    }
#endif
    return QDir::currentPath();
}

// A small, real widget tree for Squish to find, interact with and screenshot.
std::unique_ptr<QMainWindow> makeWindow()
{
    auto window = std::make_unique<QMainWindow>();
    window->setObjectName(QStringLiteral("mainWindow"));
    window->setWindowTitle(QStringLiteral("headlessQtApp"));
    window->resize(640, 400);

    auto *central = new QWidget(window.get());
    central->setObjectName(QStringLiteral("centralWidget"));
    auto *layout = new QVBoxLayout(central);

    auto *title = new QLabel(QStringLiteral("headlessQtApp %1 (Qt %2, pid %3)")
                                 .arg(QStringLiteral(HEADLESSQTAPP_VERSION),
                                      QString::fromLatin1(qVersion()),
                                      QString::number(QCoreApplication::applicationPid())),
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

    // Make the package relocatable without relying on the wrapper script or qt.conf:
    // plugins live in <pkg>/plugins and the platform is offscreen unless overridden.
    const QString pkgDir = QDir(executableDir()).absoluteFilePath(QStringLiteral(".."));
    QCoreApplication::addLibraryPath(QDir(pkgDir).absoluteFilePath(QStringLiteral("plugins")));
    if (!coreOnly && qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("offscreen"));
    if (!coreOnly && qEnvironmentVariableIsEmpty("QT_QPA_FONTDIR")) {
        const QString fontDir = QDir(pkgDir).absoluteFilePath(QStringLiteral("libs/lib64/fonts"));
        if (QDir(fontDir).exists())
            qputenv("QT_QPA_FONTDIR", QFile::encodeName(fontDir));
    }

    std::unique_ptr<QCoreApplication> app;
    if (coreOnly)
        app = std::make_unique<QCoreApplication>(argc, argv);
    else
        app = std::make_unique<QApplication>(argc, argv);

    QCoreApplication::setApplicationName(QStringLiteral("headlessQtApp"));
    QCoreApplication::setApplicationVersion(QStringLiteral(HEADLESSQTAPP_VERSION));
    QCoreApplication::setOrganizationName(QStringLiteral("headlessQtApp"));

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
    const QCommandLineOption screenshotOption(QStringLiteral("screenshot"),
        QStringLiteral("Render the main window to <file> (PNG) and exit; self-test of offscreen rendering."),
        QStringLiteral("file"));
    const QCommandLineOption desktopShotOption(QStringLiteral("desktop-screenshot"),
        QStringLiteral("Grab the primary screen (QScreen::grabWindow(0), as Squish does) to <file> (PNG) and exit."),
        QStringLiteral("file"));
    parser.addOption(onceOption);
    parser.addOption(coreOnlyOption);
    parser.addOption(screenshotOption);
    parser.addOption(desktopShotOption);
    parser.process(*app);

    if (!installSignalHandlers()) {
        std::fprintf(stderr, "headlessQtApp: failed to install signal handlers: %s\n",
                     std::strerror(errno));
        return 1;
    }
    QSocketNotifier notifier(g_signalFds[1], QSocketNotifier::Read, app.get());
    QObject::connect(&notifier, &QSocketNotifier::activated, app.get(), [&notifier]() {
        notifier.setEnabled(false);
        unsigned char byte = 0;
        const ssize_t n = ::read(g_signalFds[1], &byte, sizeof(byte));
        const int signum = (n == 1) ? static_cast<int>(byte) : 0;
        logLine(QStringLiteral("received %1, shutting down").arg(QLatin1String(signalName(signum))));
        QCoreApplication::exit(0);
    });

    logLine(QStringLiteral("started pid=%1 version=%2 mode=%3")
                .arg(QCoreApplication::applicationPid())
                .arg(QStringLiteral(HEADLESSQTAPP_VERSION),
                     coreOnly ? QStringLiteral("core-only") : QStringLiteral("widgets/offscreen")));
    logLine(QStringLiteral("qt runtime=%1 built-against=%2 core-library=%3")
                .arg(QString::fromLatin1(qVersion()), QStringLiteral(QT_VERSION_STR), loadedQtCorePath()));
    if (std::strcmp(qVersion(), QT_VERSION_STR) != 0) {
        std::fprintf(stderr, "headlessQtApp: warning: runtime Qt %s differs from build-time Qt %s\n",
                     qVersion(), QT_VERSION_STR);
        std::fflush(stderr);
    }

    std::unique_ptr<QMainWindow> window;
    if (!coreOnly) {
        logLine(QStringLiteral("qpa platform=%1 plugin-paths=%2")
                    .arg(QGuiApplication::platformName(),
                         QCoreApplication::libraryPaths().join(QLatin1Char(':'))));
        const QScreen *primary = QGuiApplication::primaryScreen();
        logLine(QStringLiteral("screens=%1 primary=%2 %3x%4")
                    .arg(QGuiApplication::screens().size())
                    .arg(primary ? primary->name() : QStringLiteral("NONE"))
                    .arg(primary ? primary->geometry().width() : 0)
                    .arg(primary ? primary->geometry().height() : 0));
        window = makeWindow();
        window->show();
        logLine(QStringLiteral("main window '%1' shown (%2x%3)")
                    .arg(window->objectName())
                    .arg(window->width()).arg(window->height()));
    }

    if (parser.isSet(desktopShotOption) && window) {
        const QString file = parser.value(desktopShotOption);
        // Give the window a few event-loop turns to be mapped and painted on the screen.
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
    } else if (parser.isSet(desktopShotOption)) {
        std::fprintf(stderr, "headlessQtApp: --desktop-screenshot is not available with --core-only\n");
        return 2;
    } else if (parser.isSet(screenshotOption) && window) {
        const QString file = parser.value(screenshotOption);
        QTimer::singleShot(0, app.get(), [&window, file]() {
            const QPixmap pixmap = window->grab();
            const bool ok = !pixmap.isNull() && pixmap.save(file, "PNG");
            logLine(QStringLiteral("screenshot %1x%2 -> %3: %4")
                        .arg(pixmap.width()).arg(pixmap.height())
                        .arg(file, ok ? QStringLiteral("saved") : QStringLiteral("FAILED")));
            QCoreApplication::exit(ok ? 0 : 2);
        });
    } else if (parser.isSet(screenshotOption)) {
        std::fprintf(stderr, "headlessQtApp: --screenshot is not available with --core-only\n");
        return 2;
    } else if (parser.isSet(onceOption)) {
        logLine(QStringLiteral("--once given: exiting after one event loop iteration"));
        QTimer::singleShot(0, app.get(), []() { QCoreApplication::exit(0); });
    } else {
        logLine(QStringLiteral("running event loop until SIGTERM or SIGINT"));
    }

    const int rc = app->exec();
    logLine(QStringLiteral("exiting with status %1").arg(rc));
    window.reset();
    ::close(g_signalFds[0]);
    ::close(g_signalFds[1]);
    return rc;
}
