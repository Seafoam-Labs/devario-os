// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only preload: capture the running UI and exit; never click or run jobs.
#include <QApplication>
#include <QCoreApplication>
#include <QTimer>
#include <QWidget>
static void scheduleCapture()
{
    QTimer::singleShot(4000, QCoreApplication::instance(), [] {
        const QString path = qEnvironmentVariable("DEVARIO_CAPTURE_PATH");
        for (QWidget* widget : QApplication::topLevelWidgets()) {
            if (widget->objectName() == "mainApp" && widget->isVisible() && !path.isEmpty()) {
                QCoreApplication::exit(widget->grab().save(path) ? 0 : 1);
                return;
            }
        }
        QCoreApplication::exit(2);
    });
}
Q_COREAPP_STARTUP_FUNCTION(scheduleCapture)
