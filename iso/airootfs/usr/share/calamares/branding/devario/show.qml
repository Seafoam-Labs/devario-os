// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick
import QtQuick.Layouts
import "Theme.js" as Pearl

Rectangle {
    id: presentation
    color: Pearl.theme.palette.container
    property bool activatedInCalamares: false
    property int page: 0
    readonly property var headings: [qsTr("Make yourself at home"), qsTr("A desktop that feels familiar"), qsTr("Almost ready")]
    readonly property var descriptions: [qsTr("Devario is being installed with the desktop and applications included on your installation media."), qsTr("Explore your applications, adjust your workspace, and make Pearl your own."), qsTr("Keep this computer connected to power. You can start using your new system when installation finishes.")]
    function onActivate() { activatedInCalamares = true }
    function onLeave() { activatedInCalamares = false }
    Timer {
        interval: 12000
        repeat: true
        running: presentation.activatedInCalamares && Pearl.theme.motionMs > 0
        onTriggered: presentation.page = (presentation.page + 1) % presentation.headings.length
    }
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.max(0, Math.min(parent.width - 32, 560))
        spacing: 20
        Image {
            source: "mark.svg"
            sourceSize: Qt.size(160, 160)
            Layout.preferredWidth: 64
            Layout.preferredHeight: 64
            Layout.alignment: Qt.AlignHCenter
            visible: presentation.height > 280
            Accessible.ignored: true
        }
        Text {
            text: presentation.headings[presentation.page]
            color: Pearl.theme.palette.text
            font.family: Pearl.theme.fontFamily
            font.pixelSize: Pearl.theme.fontPixelSize * 1.6
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }
        Text {
            text: presentation.descriptions[presentation.page]
            color: Pearl.theme.palette.secondary
            font.family: Pearl.theme.fontFamily
            font.pixelSize: Pearl.theme.fontPixelSize
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
        Row {
            Layout.alignment: Qt.AlignHCenter
            spacing: 6
            Repeater {
                model: presentation.headings.length
                Rectangle {
                    required property int index
                    width: index === presentation.page ? 24 : 8
                    height: 8
                    radius: 4
                    color: index === presentation.page ? Pearl.theme.palette.primary : Pearl.theme.palette.outline
                    Behavior on width { NumberAnimation { duration: Pearl.theme.motionMs; easing.type: Easing.OutCubic } }
                }
            }
        }
    }
}
