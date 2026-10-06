// squish-anchor: a headless, long-running Qt anchor process for Squish attachment.
//
// - QCoreApplication only (no QGuiApplication/QApplication, no QPA platform plugin,
//   no X11/Wayland, no QtGui/QtWidgets/QtQuick linkage).
// - Logs its startup and PID to standard output.
// - Runs the Qt event loop until SIGTERM or SIGINT is received, then exits with 0.
// - "--once": logs startup, spins the event loop once, exits with 0.

#include <QCoreApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QDateTime>
#include <QFile>
#include <QSocketNotifier>
#include <QString>
#include <QTimer>
#include <QtGlobal>

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>

#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef SQUISH_ANCHOR_VERSION
#define SQUISH_ANCHOR_VERSION "0.0.0"
#endif

namespace {

// Self-pipe (socketpair) used to forward Unix signals into the Qt event loop.
// This is the pattern documented in "Calling Qt Functions From Unix Signal Handlers".
int g_signalFds[2] = {-1, -1};

void unixSignalHandler(int signum)
{
    const unsigned char byte = static_cast<unsigned char>(signum);
    // write() is async-signal-safe. The result is intentionally ignored.
    const ssize_t written = ::write(g_signalFds[0], &byte, sizeof(byte));
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
    std::fprintf(stdout, "%s squish-anchor[%lld]: %s\n",
                 qPrintable(stamp),
                 static_cast<long long>(QCoreApplication::applicationPid()),
                 qPrintable(message));
    std::fflush(stdout);
}

// Path of the Qt Core library mapped into this process (Linux only, best effort).
QString loadedQtCorePath()
{
#ifdef Q_OS_LINUX
    QFile maps(QStringLiteral("/proc/self/maps"));
    if (maps.open(QIODevice::ReadOnly | QIODevice::Text)) {
        while (!maps.atEnd()) {
            const QString line = QString::fromLocal8Bit(maps.readLine()).trimmed();
            const int idx = line.indexOf(QLatin1Char('/'));
            if (idx < 0)
                continue;
            const QString path = line.mid(idx);
            if (path.contains(QLatin1String("libQt6Core.so")))
                return path;
        }
    }
#endif
    return QStringLiteral("(unknown)");
}

} // namespace

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("squish-anchor"));
    QCoreApplication::setApplicationVersion(QStringLiteral(SQUISH_ANCHOR_VERSION));
    QCoreApplication::setOrganizationName(QStringLiteral("squish-anchor"));

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("Headless Qt anchor process for Squish attachment. "
                       "Runs the Qt event loop until SIGTERM or SIGINT."));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption onceOption(
        QStringLiteral("once"),
        QStringLiteral("Log startup, run the event loop once and exit successfully."));
    parser.addOption(onceOption);
    parser.process(app);

    if (!installSignalHandlers()) {
        std::fprintf(stderr, "squish-anchor: failed to install signal handlers: %s\n",
                     std::strerror(errno));
        return 1;
    }

    // Deliver forwarded signals on the event loop thread.
    QSocketNotifier notifier(g_signalFds[1], QSocketNotifier::Read, &app);
    QObject::connect(&notifier, &QSocketNotifier::activated, &app, [&notifier]() {
        notifier.setEnabled(false);
        unsigned char byte = 0;
        const ssize_t n = ::read(g_signalFds[1], &byte, sizeof(byte));
        const int signum = (n == 1) ? static_cast<int>(byte) : 0;
        logLine(QStringLiteral("received %1, shutting down").arg(QLatin1String(signalName(signum))));
        QCoreApplication::exit(0);
    });

    logLine(QStringLiteral("started pid=%1 version=%2")
                .arg(QCoreApplication::applicationPid())
                .arg(QStringLiteral(SQUISH_ANCHOR_VERSION)));
    logLine(QStringLiteral("qt runtime=%1 built-against=%2 core-library=%3")
                .arg(QString::fromLatin1(qVersion()), QStringLiteral(QT_VERSION_STR), loadedQtCorePath()));
    if (std::strcmp(qVersion(), QT_VERSION_STR) != 0) {
        std::fprintf(stderr,
                     "squish-anchor: warning: runtime Qt %s differs from build-time Qt %s\n",
                     qVersion(), QT_VERSION_STR);
        std::fflush(stderr);
    }

    if (parser.isSet(onceOption)) {
        logLine(QStringLiteral("--once given: exiting after one event loop iteration"));
        QTimer::singleShot(0, &app, []() { QCoreApplication::exit(0); });
    } else {
        logLine(QStringLiteral("running event loop until SIGTERM or SIGINT"));
    }

    const int rc = app.exec();
    logLine(QStringLiteral("exiting with status %1").arg(rc));

    ::close(g_signalFds[0]);
    ::close(g_signalFds[1]);
    return rc;
}
