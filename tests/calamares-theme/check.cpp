// SPDX-License-Identifier: GPL-3.0-or-later
#include "PearlStyle.h"
#include <QApplication>
#include <QAccessible>
#include <QCheckBox>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFile>
#include <QFormLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QJsonDocument>
#include <QLabel>
#include <QLineEdit>
#include <QListView>
#include <QProgressBar>
#include <QPushButton>
#include <QQuickWidget>
#include <QQuickItem>
#include <QRadioButton>
#include <QScrollArea>
#include <QSpinBox>
#include <QSignalSpy>
#include <QStandardItemModel>
#include <QTableWidget>
#include <QTemporaryDir>
#include <QTest>
#include <QVariantAnimation>
#include <QQmlEngine>

class BrandingFixture : public QObject {
    Q_OBJECT
public:
    enum Entry { ProductName };
    Q_ENUM(Entry)
    Q_INVOKABLE QString string(int) const { return "Devario"; }
};
class StepsFixture : public QStandardItemModel {
    Q_OBJECT
    Q_PROPERTY(int currentStepIndex READ currentStepIndex NOTIFY currentStepChanged)
public:
    int currentStepIndex() const { return 3; }
signals:
    void currentStepChanged();
};

class ThemeChecks : public QObject {
    Q_OBJECT
    QString directory = qEnvironmentVariable("DEVARIO_THEME_DIR");
    QString captures = qEnvironmentVariable("DEVARIO_THEME_CAPTURES");
    QJsonObject theme;
    void capture(QWidget& widget, const QString& name) {
        if (!captures.isEmpty()) QVERIFY(widget.grab().save(captures + "/" + name + ".png"));
    }
private slots:
    void initTestCase() {
        QFile file(directory + "/theme.json");
        QVERIFY(file.open(QIODevice::ReadOnly));
        theme = QJsonDocument::fromJson(file.readAll()).object();
        QString error;
        QVERIFY2(Devario::applyPearlTheme(*qApp, directory, &error), qPrintable(error));
    }
    void paletteAndDetachedDialog() {
        QDialog dialog;
        QCOMPARE(dialog.palette().color(QPalette::Text), QColor(theme["palette"].toObject()["text"].toString()));
        QCOMPARE(dialog.palette().color(QPalette::Base), QColor(theme["palette"].toObject()["low"].toString()));
        QCOMPARE(qApp->font().pixelSize(), theme["fontPixelSize"].toInt());
        QVERIFY(qApp->property("devarioPearlTheme").toBool());
    }
    void nativeKeyboardAndAccessibility() {
        QWidget window;
        auto* layout = new QVBoxLayout(&window);
        auto* field = new QLineEdit;
        auto* check = new QCheckBox("Encrypt the system");
        auto* button = new QPushButton("&Next");
        button->setObjectName("view-button-next");
        layout->addWidget(field); layout->addWidget(check); layout->addWidget(button);
        window.show();
        window.activateWindow();
        QTest::qWait(50);
        field->setFocus();
        QTest::keyClicks(field, "example-user");
        QCOMPARE(field->text(), QString("example-user"));
        QTest::keyClick(field, Qt::Key_Tab);
        QVERIFY(check->hasFocus());
        QTest::keyClick(check, Qt::Key_Space);
        QVERIFY(check->isChecked());
        auto* interface = QAccessible::queryAccessibleInterface(check);
        QVERIFY(interface);
        QCOMPARE(interface->role(), QAccessible::CheckBox);
        QVERIFY(interface->state().checked);
        QSignalSpy clicks(button, &QPushButton::clicked);
        button->setFocus();
        QTest::keyClick(button, Qt::Key_Space);
        QCOMPARE(clicks.count(), 1);
        button->setEnabled(false);
        QTest::keyClick(button, Qt::Key_Space);
        QCOMPARE(clicks.count(), 1);
    }
    void motionAndFocus() {
        QPushButton button("Continue");
        button.resize(150, 46);
        button.show();
        button.activateWindow();
        QTest::qWait(30);
        QEvent enter(QEvent::Enter);
        QApplication::sendEvent(&button, &enter);
        auto* animation = button.findChild<QVariantAnimation*>("pearlHover");
        QVERIFY(animation);
        if (theme["motionMs"].toInt() == 0) QCOMPARE(animation->state(), QAbstractAnimation::Stopped);
        else QTRY_COMPARE(animation->state(), QAbstractAnimation::Stopped);
        QCOMPARE(button.property("pearlHoverValue").toReal(), 1.0);
        button.setFocus();
        QVERIFY(button.hasFocus());
        capture(button, "focused-button");
    }
    void primaryButtonTextContrast() {
        QPushButton button("Continue");
        button.setObjectName("view-button-next");
        button.resize(160, 46); button.show(); QTest::qWait(20);
        const QImage image = button.grab().toImage();
        const QColor expected(theme["palette"].toObject()["onPrimary"].toString());
        int matching = 0;
        for (int y = 0; y < image.height(); ++y)
            for (int x = 0; x < image.width(); ++x)
                {
                    const QColor pixel = image.pixelColor(x, y);
                    const int distance = qAbs(pixel.red() - expected.red()) + qAbs(pixel.green() - expected.green()) + qAbs(pixel.blue() - expected.blue());
                    if (distance < 70) ++matching;
                }
        QVERIFY2(matching > 4, "Primary button label must use the contrasting on-primary color");
    }
    void controlsAndPartitionFixture() {
        QWidget window;
        window.setObjectName("mainApp");
        window.setWindowTitle("Devario — appearance fixture");
        auto* outer = new QVBoxLayout(&window);
        auto* title = new QLabel("Choose where to install Devario");
        QFont heading = title->font(); heading.setPixelSize(23); heading.setWeight(QFont::DemiBold); title->setFont(heading);
        outer->addWidget(title);
        outer->addWidget(new QLabel("Review the disk and partition layout before continuing."));
        auto* card = new QGroupBox("Installation destination");
        auto* form = new QFormLayout(card);
        auto* device = new QComboBox;
        device->addItems({"Virtual disk — 128 GiB (/dev/vda)", "Second disk — 256 GiB (/dev/vdb)"});
        form->addRow("Storage device", device);
        auto* erase = new QRadioButton("Erase disk"); erase->setChecked(true);
        form->addRow(erase);
        form->addRow(new QRadioButton("Manual partitioning"));
        auto* encrypt = new QCheckBox("Encrypt the system"); encrypt->setChecked(true); form->addRow(encrypt);
        auto* password = new QLineEdit("synthetic-password"); password->setEchoMode(QLineEdit::Password); form->addRow("Passphrase", password);
        auto* disabled = new QLineEdit("Unavailable option"); disabled->setEnabled(false); form->addRow("Disabled", disabled);
        auto* table = new QTableWidget(3, 3);
        table->setHorizontalHeaderLabels({"Partition", "File system", "Size"});
        const QStringList cells = {"/boot", "FAT32", "4 GiB", "/", "Btrfs", "116 GiB", "swap", "Linux swap", "8 GiB"};
        for (int i = 0; i < cells.size(); ++i) table->setItem(i / 3, i % 3, new QTableWidgetItem(cells[i]));
        table->setSelectionBehavior(QAbstractItemView::SelectRows); table->selectRow(1);
        table->horizontalHeader()->setStretchLastSection(true);
        form->addRow(table);
        outer->addWidget(card);
        auto* progress = new QProgressBar; progress->setValue(42); progress->setTextVisible(false); outer->addWidget(progress);
        auto* buttons = new QDialogButtonBox;
        buttons->addButton("Cancel", QDialogButtonBox::RejectRole);
        buttons->addButton("Back", QDialogButtonBox::ActionRole);
        auto* next = buttons->addButton("Next", QDialogButtonBox::AcceptRole); next->setObjectName("view-button-next");
        outer->addWidget(buttons);
        window.resize(800, 650); window.show();
        QTest::qWait(100);
        QVERIFY(window.rect().contains(next->mapTo(&window, next->rect().bottomRight())));
        capture(window, "partition-controls");
        window.setLayoutDirection(Qt::RightToLeft);
        QTest::qWait(50); capture(window, "partition-controls-rtl");
    }
    void qmlComponents() {
        BrandingFixture branding;
        StepsFixture steps;
        for (const auto& label : {"Welcome", "Location", "Keyboard", "Partitions", "Users", "Summary", "Install", "Finish"})
            steps.appendRow(new QStandardItem(label));
        qmlRegisterSingletonInstance("io.calamares.ui", 1, 0, "Branding", &branding);
        qmlRegisterSingletonInstance("io.calamares.ui", 1, 0, "ViewManager", &steps);
        for (const auto& name : {"calamares-sidebar", "show"}) {
            QQuickWidget quick;
            quick.setResizeMode(QQuickWidget::SizeRootObjectToView);
            quick.resize(QString(name) == "show" ? 640 : 208, 520);
            quick.setSource(QUrl::fromLocalFile(directory + "/" + name + ".qml"));
            for (const auto& error : quick.errors()) qWarning() << error;
            QCOMPARE(quick.status(), QQuickWidget::Ready);
            quick.show(); QTest::qWait(100);
            QVERIFY(quick.rootObject());
            capture(quick, name);
            if (QString(name) == "calamares-sidebar") {
                quick.resize(88, 360); QTest::qWait(30);
                QCOMPARE(quick.rootObject()->width(), 88.0);
                capture(quick, "sidebar-compact");
            }
        }
    }
    void invalidThemeDoesNotMutateApplication() {
        QTemporaryDir temp;
        QFile file(temp.filePath("theme.json")); QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("{\"schemaVersion\":1,\"palette\":{}}"); file.close();
        const auto before = qApp->palette();
        QString error;
        QVERIFY(!Devario::applyPearlTheme(*qApp, temp.path(), &error));
        QVERIFY(!error.isEmpty());
        QCOMPARE(qApp->palette(), before);
    }
};
int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ThemeChecks checks;
    return QTest::qExec(&checks, argc, argv);
}
#include "check.moc"
