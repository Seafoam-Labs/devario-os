// SPDX-License-Identifier: GPL-3.0-or-later
#include "PearlStyle.h"
#include <QApplication>
#include <QAbstractButton>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFontDatabase>
#include <QJsonDocument>
#include <QPainter>
#include <QPainterPath>
#include <QPushButton>
#include <QRegularExpression>
#include <QStyleFactory>
#include <QStyleOptionButton>
#include <QVariantAnimation>

namespace Devario {
namespace {
QColor blend(const QColor& a, const QColor& b, qreal amount)
{
    return QColor::fromRgbF(a.redF() * (1 - amount) + b.redF() * amount,
                           a.greenF() * (1 - amount) + b.greenF() * amount,
                           a.blueF() * (1 - amount) + b.blueF() * amount);
}
bool primary(const QStyleOptionButton* button, const QWidget* widget)
{
    return (button && (button->features & QStyleOptionButton::DefaultButton))
        || (widget && (widget->objectName() == "view-button-next" || widget->property("pearlPrimary").toBool()));
}
}
PearlStyle::PearlStyle(const QJsonObject& theme)
    : QProxyStyle(QStyleFactory::create("Fusion")), m_palette(theme["palette"].toObject()),
      m_motionMs(theme["motionMs"].toInt()), m_spacing(theme["spacing"].toInt())
{
    setObjectName("DevarioPearl");
}
QColor PearlStyle::color(const char* key) const { return QColor(m_palette[key].toString()); }
void PearlStyle::polish(QWidget* widget)
{
    QProxyStyle::polish(widget);
    if (widget->objectName() == "mainApp") widget->installEventFilter(this);
    if (qobject_cast<QPushButton*>(widget)) {
        widget->setAttribute(Qt::WA_Hover);
        widget->installEventFilter(this);
    }
}
void PearlStyle::unpolish(QWidget* widget)
{
    widget->removeEventFilter(this);
    QProxyStyle::unpolish(widget);
}
bool PearlStyle::eventFilter(QObject* object, QEvent* event)
{
    if (event->type() == QEvent::Resize && object->objectName() == "mainApp") {
        auto* window = qobject_cast<QWidget*>(object);
        if (auto* sidebar = window->findChild<QWidget*>("pearlSidebar"))
            sidebar->setFixedWidth(window->width() < 620 ? 88 : qBound(144, window->width() / 5, 224));
    }
    auto* widget = qobject_cast<QPushButton*>(object);
    if (widget && (event->type() == QEvent::Enter || event->type() == QEvent::Leave || event->type() == QEvent::EnabledChange)) {
        auto* animation = widget->findChild<QVariantAnimation*>("pearlHover", Qt::FindDirectChildrenOnly);
        if (!animation) {
            animation = new QVariantAnimation(widget);
            animation->setObjectName("pearlHover");
            connect(animation, &QVariantAnimation::valueChanged, widget, [widget](const QVariant& value) {
                widget->setProperty("pearlHoverValue", value);
                widget->update();
            });
        }
        animation->stop();
        const qreal target = event->type() == QEvent::Enter && widget->isEnabled() ? 1.0 : 0.0;
        if (m_motionMs == 0) {
            widget->setProperty("pearlHoverValue", target);
            widget->update();
        } else {
            animation->setStartValue(widget->property("pearlHoverValue").toReal());
            animation->setEndValue(target);
            animation->setDuration(m_motionMs);
            animation->setEasingCurve(QEasingCurve::OutCubic);
            animation->start();
        }
    }
    return QProxyStyle::eventFilter(object, event);
}
int PearlStyle::pixelMetric(PixelMetric metric, const QStyleOption* option, const QWidget* widget) const
{
    switch (metric) {
    case PM_LayoutHorizontalSpacing: case PM_LayoutVerticalSpacing: return m_spacing;
    case PM_LayoutLeftMargin: case PM_LayoutRightMargin:
    case PM_LayoutTopMargin: case PM_LayoutBottomMargin: return 12;
    case PM_IndicatorWidth: case PM_IndicatorHeight:
    case PM_ExclusiveIndicatorWidth: case PM_ExclusiveIndicatorHeight: return 20;
    case PM_ButtonMargin: return 16;
    default: return QProxyStyle::pixelMetric(metric, option, widget);
    }
}
int PearlStyle::styleHint(StyleHint hint, const QStyleOption* option, const QWidget* widget, QStyleHintReturn* result) const
{
    if (hint == SH_Widget_Animation_Duration) return m_motionMs;
    if (hint == SH_UnderlineShortcut) return true;
    return QProxyStyle::styleHint(hint, option, widget, result);
}
QSize PearlStyle::sizeFromContents(ContentsType type, const QStyleOption* option, const QSize& size, const QWidget* widget) const
{
    QSize result = QProxyStyle::sizeFromContents(type, option, size, widget);
    if (type == CT_PushButton) result = result.expandedTo(QSize(size.width() + 36, size.height() + 22));
    return result;
}
void PearlStyle::drawControl(ControlElement element, const QStyleOption* option, QPainter* painter, const QWidget* widget) const
{
    const auto* button = qstyleoption_cast<const QStyleOptionButton*>(option);
    if (!button || (element != CE_PushButtonBevel && element != CE_PushButtonLabel)) {
        QProxyStyle::drawControl(element, option, painter, widget);
        return;
    }
    const bool enabled = option->state & State_Enabled;
    const bool selected = primary(button, widget) || (option->state & State_On);
    const QColor foreground = color(!enabled ? "secondary" : selected ? "onPrimary" : "text");
    if (element == CE_PushButtonLabel) {
        // Paint the label directly: QStyleSheetStyle otherwise re-resolves
        // ButtonText through the application palette after this override.
        painter->save();
        if (widget) painter->setFont(widget->font());
        painter->setPen(foreground);
        QRect textRect = button->rect;
        if (!button->icon.isNull()) {
            const QSize iconSize = button->iconSize.isValid() ? button->iconSize : QSize(16, 16);
            const int textWidth = button->fontMetrics.size(Qt::TextShowMnemonic, button->text).width();
            const int total = iconSize.width() + 8 + textWidth;
            QRect iconRect(button->rect.center().x() - total / 2,
                           button->rect.center().y() - iconSize.height() / 2, iconSize.width(), iconSize.height());
            textRect.setLeft(iconRect.right() + 9);
            textRect.setWidth(textWidth);
            iconRect = visualRect(button->direction, button->rect, iconRect);
            textRect = visualRect(button->direction, button->rect, textRect);
            button->icon.paint(painter, iconRect, Qt::AlignCenter,
                               enabled ? QIcon::Normal : QIcon::Disabled,
                               (button->state & State_On) ? QIcon::On : QIcon::Off);
        }
        painter->drawText(textRect, Qt::AlignCenter | Qt::TextShowMnemonic, button->text);
        painter->restore();
        return;
    }
    QColor background = color(!enabled ? "low" : selected ? "primary" : "high");
    const qreal hover = widget ? widget->property("pearlHoverValue").toReal() : ((option->state & State_MouseOver) ? 1.0 : 0.0);
    if (enabled) background = blend(background, color(selected ? "onPrimary" : "primary"),
                                   (option->state & State_Sunken) ? 0.20 : hover * 0.12);
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    const QRectF rect = QRectF(option->rect).adjusted(3, 3, -3, -3);
    painter->setPen(Qt::NoPen);
    painter->setBrush(background);
    painter->drawRoundedRect(rect, rect.height() / 2, rect.height() / 2);
    if (enabled && (option->state & State_HasFocus)) {
        painter->setBrush(Qt::NoBrush);
        painter->setPen(QPen(color("primary"), 2));
        painter->drawRoundedRect(rect.adjusted(-2, -2, 2, 2), rect.height() / 2 + 2, rect.height() / 2 + 2);
    }
    painter->restore();
}
void PearlStyle::drawPrimitive(PrimitiveElement element, const QStyleOption* option, QPainter* painter, const QWidget* widget) const
{
    if (element == PE_FrameFocusRect) {
        if (qobject_cast<const QPushButton*>(widget)) return; // Painted with the pill.
        painter->save();
        painter->setRenderHint(QPainter::Antialiasing);
        painter->setBrush(Qt::NoBrush);
        painter->setPen(QPen(color("primary"), 2));
        painter->drawRoundedRect(QRectF(option->rect).adjusted(1, 1, -1, -1), 4, 4);
        painter->restore();
        return;
    }
    if (element != PE_IndicatorCheckBox && element != PE_IndicatorRadioButton) {
        QProxyStyle::drawPrimitive(element, option, painter, widget);
        return;
    }
    const bool checked = option->state & (State_On | State_NoChange);
    const bool enabled = option->state & State_Enabled;
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    QRectF rect = QRectF(option->rect).adjusted(2, 2, -2, -2);
    painter->setPen(QPen(color(enabled && checked ? "primary" : "outline"), 1.5));
    painter->setBrush(color(checked && enabled ? "primary" : "low"));
    const qreal radius = element == PE_IndicatorRadioButton ? rect.height() / 2 : 4;
    painter->drawRoundedRect(rect, radius, radius);
    if (checked) {
        painter->setPen(QPen(color(enabled ? "onPrimary" : "secondary"), 2, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        if (element == PE_IndicatorRadioButton) {
            painter->setPen(Qt::NoPen);
            painter->setBrush(color(enabled ? "onPrimary" : "secondary"));
            painter->drawEllipse(rect.center(), 3.5, 3.5);
        } else if (option->state & State_NoChange) {
            painter->drawLine(rect.center() + QPointF(-4, 0), rect.center() + QPointF(4, 0));
        } else {
            QPainterPath path;
            path.moveTo(rect.left() + 3, rect.center().y());
            path.lineTo(rect.left() + 6, rect.bottom() - 4);
            path.lineTo(rect.right() - 3, rect.top() + 4);
            painter->drawPath(path);
        }
    }
    painter->restore();
}

bool applyPearlTheme(QApplication& app, const QString& directory, QString* error)
{
    auto fail = [error](const QString& message) { if (error) *error = message; return false; };
    QFile config(QDir(directory).filePath("theme.json"));
    if (!config.open(QIODevice::ReadOnly)) return fail("Cannot read Pearl theme.json");
    QJsonParseError parseError;
    const auto document = QJsonDocument::fromJson(config.readAll(), &parseError);
    const auto theme = document.object();
    if (parseError.error != QJsonParseError::NoError || theme["schemaVersion"].toInt() != 1)
        return fail("Invalid Pearl theme schema");
    const auto colors = theme["palette"].toObject();
    for (const char* role : {"surface", "low", "container", "high", "text", "secondary", "primary", "onPrimary",
                             "primaryContainer", "onContainer", "outline", "error", "errorContainer"}) {
        if (!QRegularExpression("^#[0-9a-fA-F]{6}$").match(colors[role].toString()).hasMatch())
            return fail(QString("Invalid Pearl palette role: %1").arg(role));
    }
    const int fontSize = theme["fontPixelSize"].toInt();
    const int motion = theme["motionMs"].toInt(-1);
    if (fontSize < 10 || fontSize > 24 || motion < 0 || motion > 1000 || theme["spacing"].toInt() < 2 || theme["spacing"].toInt() > 24)
        return fail("Invalid Pearl font, motion or spacing");
    QFile sheet(QDir(directory).filePath("stylesheet.qss"));
    if (!sheet.open(QIODevice::ReadOnly)) return fail("Cannot read Pearl stylesheet");
    QString qss = QString::fromUtf8(sheet.readAll());
    qss.replace("@BRANDING_DIR@", QDir(directory).absolutePath());
    QPalette palette;
    auto set = [&](QPalette::ColorRole role, const char* key) { palette.setColor(role, QColor(colors[key].toString())); };
    set(QPalette::Window, "container"); set(QPalette::WindowText, "text");
    set(QPalette::Base, "low"); set(QPalette::AlternateBase, "container");
    set(QPalette::Text, "text"); set(QPalette::Button, "high"); set(QPalette::ButtonText, "text");
    set(QPalette::Highlight, "primaryContainer"); set(QPalette::HighlightedText, "onContainer");
    set(QPalette::ToolTipBase, "high"); set(QPalette::ToolTipText, "text");
    set(QPalette::Link, "primary"); set(QPalette::LinkVisited, "primary");
    set(QPalette::Light, "high"); set(QPalette::Midlight, "high");
    set(QPalette::Mid, "outline"); set(QPalette::Dark, "low"); set(QPalette::Shadow, "surface");
    set(QPalette::PlaceholderText, "secondary");
#if QT_VERSION >= QT_VERSION_CHECK(6, 6, 0)
    set(QPalette::Accent, "primary");
#endif
    for (auto role : {QPalette::WindowText, QPalette::Text, QPalette::ButtonText, QPalette::PlaceholderText})
        palette.setColor(QPalette::Disabled, role, QColor(colors["secondary"].toString()));
    app.setStyle(new PearlStyle(theme));
    app.setPalette(palette);
    QFont font;
    font.setFamilies({theme["fontFamily"].toString(), "Noto Sans", "sans-serif"});
    font.setPixelSize(fontSize);
    app.setFont(font);
    app.setStyleSheet(qss);
    app.setProperty("devarioPearlTheme", true);
    app.setProperty("devarioPearlPalette", colors.toVariantMap());
    return true;
}
}
