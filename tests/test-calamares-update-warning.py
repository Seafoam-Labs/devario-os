#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the patched FinishedPage against Qt and exercise its real widget.

Pass a pristine, unpacked Calamares 3.4.2 source directory. Only the application
singletons and restart configuration are stubbed; no installer or reboot runs.
Requires g++, pkg-config, Qt6 Widgets development files, moc, uic and patch.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="devario-finished-test-") as directory:
        root = Path(directory)
        module = root / "src/modules/finished"
        shutil.copytree(args.source / "src/modules/finished", module)
        patch = PROJECT / "packages/calamares/0003-devario-update-warning.patch"
        subprocess.run(["patch", "-p1", "-i", str(patch)], cwd=root, check=True)
        # Substitute only the live result pathname to avoid writing into /run.
        page = module / "FinishedPage.cpp"
        original = page.read_text()
        assert original.count("/run/devario-installer-update/result.json") == 1
        page.write_text(original.replace("/run/devario-installer-update/result.json", str(root / "result.json")))
        assert "m_widget->retranslate();" in (module / "FinishedViewStep.cpp").read_text()
        (module / "Config.h").write_text('''#pragma once
#include <QObject>
class Config : public QObject {
    Q_OBJECT
public:
    enum class RestartMode { Never, UserDefaultUnchecked, UserDefaultChecked, Always };
    bool wanted = false;
    void setRestartNowWanted(bool value) { wanted = value; emit restartNowWantedChanged(value); }
signals:
    void restartModeChanged(RestartMode);
    void restartNowWantedChanged(bool);
};
''')
        (module / "Branding.h").write_text('''#pragma once
#include <QString>
namespace Calamares { class Branding {
public:
    static Branding* instance() { static Branding value; return &value; }
    QString versionedName() const { return "Devario Test"; }
    QString productName() const { return "Devario"; }
}; }
''')
        (module / "Settings.h").write_text('''#pragma once
namespace Calamares { class Settings {
public:
    bool setup = false;
    static Settings* instance() { static Settings value; return &value; }
    bool isSetupMode() const { return setup; }
}; }
''')
        (module / "utils").mkdir()
        (module / "utils/Retranslator.h").write_text(
            "#define CALAMARES_RETRANSLATE_SLOT(slot) (this->*slot)()\n")
        (module / "check.cpp").write_text('''#include "FinishedPage.h"
#include "Config.h"
#include "Settings.h"
#include <QApplication>
#include <QCheckBox>
#include <QFile>
#include <QLabel>
#include <cassert>
int main(int argc, char** argv) {
    QApplication app(argc, argv);
    Config config;
    FinishedPage page(&config);
    auto label = page.findChild<QLabel*>("mainText");
    auto restart = page.findChild<QCheckBox*>("restartCheckBox");
    assert(label && restart);
    assert(!label->text().contains("updates pending"));
    QFile result(argv[1]);
    auto write = [&](const QByteArray& data) {
        assert(result.open(QIODevice::WriteOnly | QIODevice::Truncate));
        result.write(data); result.close(); page.retranslate();
    };
    write(R"({"status":"updates-pending","reason":"Offline <b>network</b> & DNS"})");
    assert(label->text().contains("Installation complete — updates pending"));
    assert(label->text().contains("use Shelly"));
    assert(label->text().contains("&lt;b&gt;network&lt;/b&gt; &amp; DNS"));
    config.restartModeChanged(Config::RestartMode::UserDefaultUnchecked);
    assert(!restart->isHidden() && restart->isEnabled());
    restart->setChecked(true);
    assert(config.wanted);
    write(R"({"status":"complete"})");
    assert(!label->text().contains("updates pending"));
    write("invalid json");
    assert(!label->text().contains("updates pending"));
    write(R"({"status":"updates-pending","reason":"Offline"})");
    Calamares::Settings::instance()->setup = true;
    page.retranslate();
    assert(!label->text().contains("updates pending"));
    Calamares::Settings::instance()->setup = false;
    page.onInstallationFailed("Upgrade failed", "Partial transaction");
    assert(label->text().contains("Installation Failed"));
    assert(!label->text().contains("updates pending"));
}
''')
        qt_libexec = subprocess.check_output(["pkg-config", "--variable=libexecdir", "Qt6Core"], text=True).strip()
        for tool, source, output in (("uic", "FinishedPage.ui", "ui_FinishedPage.h"),
                                     ("moc", "FinishedPage.h", "moc_page.cpp"),
                                     ("moc", "Config.h", "moc_config.cpp")):
            subprocess.run([str(Path(qt_libexec) / tool), str(module / source), "-o", str(module / output)], check=True)
        flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "Qt6Widgets"], text=True).split()
        subprocess.run(["g++", "-std=c++17", "-fPIC", "-I" + str(module),
                        "-I" + str(args.source.resolve() / "src/libcalamares"),
                        *[str(module / name) for name in ("FinishedPage.cpp", "moc_page.cpp", "moc_config.cpp", "check.cpp")],
                        "-o", str(root / "check"), *flags], check=True)
        subprocess.run([str(root / "check"), str(root / "result.json")],
                       env=dict(os.environ, QT_QPA_PLATFORM="offscreen"), check=True)
        print("FinishedPage: warning, escaping, restart, success, setup and fatal failure checks passed")


if __name__ == "__main__":
    main()
