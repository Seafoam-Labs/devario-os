// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import io.calamares.ui 1.0
import "Theme.js" as Pearl

Rectangle {
    id: sidebar
    color: Pearl.theme.palette.surface
    implicitWidth: 208
    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 16

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Image {
                source: "mark.svg"
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                sourceSize: Qt.size(72, 72)
                Accessible.ignored: true
            }
            Text {
                visible: sidebar.width >= 140
                text: Branding.string(Branding.ProductName)
                color: Pearl.theme.palette.text
                font.family: Pearl.theme.fontFamily
                font.pixelSize: Pearl.theme.fontPixelSize + 4
                font.weight: Font.DemiBold
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        ListView {
            id: steps
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: ViewManager
            currentIndex: ViewManager.currentStepIndex
            spacing: 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                id: step
                required property int index
                required property string display
                readonly property bool current: index === ViewManager.currentStepIndex
                readonly property bool complete: index < ViewManager.currentStepIndex
                width: ListView.view.width
                height: Math.max(44, stepLabel.implicitHeight + 20)
                radius: 16
                color: current ? Pearl.theme.palette.primaryContainer : "transparent"
                Behavior on color { ColorAnimation { duration: Pearl.theme.motionMs } }
                Accessible.role: Accessible.ListItem
                Accessible.name: display
                Accessible.description: current ? qsTr("Current step") : (complete ? qsTr("Completed step") : qsTr("Upcoming step"))
                Accessible.focusable: false
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 8
                    Text {
                        text: step.complete ? "✓" : String(step.index + 1)
                        color: step.current ? Pearl.theme.palette.onContainer : Pearl.theme.palette.primary
                        font.family: Pearl.theme.fontFamily
                        font.pixelSize: Pearl.theme.fontPixelSize
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                        Layout.preferredWidth: 22
                        Accessible.ignored: true
                    }
                    Text {
                        id: stepLabel
                        visible: sidebar.width >= 140
                        text: step.display
                        color: step.current ? Pearl.theme.palette.onContainer : Pearl.theme.palette.secondary
                        font.family: Pearl.theme.fontFamily
                        font.pixelSize: Pearl.theme.fontPixelSize
                        font.weight: step.current ? Font.DemiBold : Font.Normal
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        Accessible.ignored: true
                    }
                }
            }
        }
    }
}
