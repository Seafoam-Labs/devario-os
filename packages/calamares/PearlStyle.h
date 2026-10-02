// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <QProxyStyle>
#include <QJsonObject>

class QApplication;
namespace Devario {
// Original Qt implementation of the measured Pearl appearance.
class PearlStyle final : public QProxyStyle
{
public:
    explicit PearlStyle(const QJsonObject& theme);
    void polish(QWidget* widget) override;
    void unpolish(QWidget* widget) override;
    int pixelMetric(PixelMetric metric, const QStyleOption* option = nullptr,
                    const QWidget* widget = nullptr) const override;
    int styleHint(StyleHint hint, const QStyleOption* option = nullptr,
                  const QWidget* widget = nullptr, QStyleHintReturn* result = nullptr) const override;
    QSize sizeFromContents(ContentsType type, const QStyleOption* option,
                          const QSize& size, const QWidget* widget) const override;
    void drawControl(ControlElement element, const QStyleOption* option,
                     QPainter* painter, const QWidget* widget = nullptr) const override;
    void drawPrimitive(PrimitiveElement element, const QStyleOption* option,
                       QPainter* painter, const QWidget* widget = nullptr) const override;
protected:
    bool eventFilter(QObject* object, QEvent* event) override;
private:
    QColor color(const char* key) const;
    QJsonObject m_palette;
    int m_motionMs;
    int m_spacing;
};
// Returns false with a diagnostic before changing the application if malformed.
bool applyPearlTheme(QApplication& app, const QString& directory, QString* error);
}
