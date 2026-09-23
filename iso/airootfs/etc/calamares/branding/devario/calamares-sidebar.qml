import io.calamares.ui 1.0
import io.calamares.core 1.0
import QtQuick 2.3
import QtQuick.Layouts 1.3

Rectangle {
    id: sideBar;
    color: Branding.styleString( Branding.SidebarBackground );
    width: 220;
    height: parent ? parent.height : 0;

    ColumnLayout {
        anchors.fill: parent;
        anchors.topMargin: 24;
        anchors.bottomMargin: 24;
        spacing: 4;

        Repeater {
            model: ViewManager;
            Rectangle {
                Layout.leftMargin: 12;
                Layout.rightMargin: 12;
                Layout.fillWidth: true;
                Layout.preferredHeight: 40;
                radius: 6;
                color: Branding.styleString( index == ViewManager.currentStepIndex ? Branding.SidebarBackgroundCurrent : Branding.SidebarBackground );

                Text {
                    anchors.fill: parent;
                    anchors.leftMargin: 16;
                    horizontalAlignment: Text.AlignLeft;
                    verticalAlignment: Text.AlignVCenter;
                    color: Branding.styleString( index == ViewManager.currentStepIndex ? Branding.SidebarTextCurrent : Branding.SidebarText );
                    text: display;
                    wrapMode: Text.WordWrap;
                    font.weight: (index == ViewManager.currentStepIndex ? Font.Bold : Font.Normal);
                    font.pointSize: 10;
                }
            }
        }

        Item {
            Layout.fillHeight: true;
        }
    }
}
