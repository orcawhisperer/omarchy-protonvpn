import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// A shield drawn natively, in the theme's colour, so it stays crisp in a
// 12px bar slot. All three states share one outer outline, so the bar icon
// never changes size:
//   connected     solid shield with a check cut out of it
//   disconnected  hollow shield
//   connecting    hollow shield whose core breathes
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property string mode: "disconnected"   // connected | disconnected | connecting | disconnecting

  readonly property bool solid: mode === "connected"
  readonly property bool working: mode === "connecting" || mode === "disconnecting"

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property string outer: "M12 1.6 L20.6 4.8 V11 C20.6 16.3 16.9 20.9 12 22.4 C7.1 20.9 3.4 16.3 3.4 11 V4.8 Z"
  readonly property string inner: "M12 4.3 L18.2 6.6 V11 C18.2 15 15.6 18.6 12 19.9 C8.4 18.6 5.8 15 5.8 11 V6.6 Z"
  readonly property string check: "M6.48 13.12 L10.60 17.24 L17.52 10.32 L15.68 8.48 L10.60 13.56 L8.32 11.28 Z"

  Shape {
    id: shape
    width: 24
    height: 24
    scale: root.iconSize / 24
    transformOrigin: Item.TopLeft
    preferredRendererType: Shape.CurveRenderer

    // Outline, or the solid body with the check as a hole.
    ShapePath {
      fillRule: ShapePath.OddEvenFill
      strokeWidth: -1
      strokeColor: "transparent"
      fillColor: root.color
      PathSvg { path: root.outer + " " + (root.solid ? root.check : root.inner) }
    }

    // The core that fills in while a connection is being made or torn down.
    ShapePath {
      id: core
      strokeWidth: -1
      strokeColor: "transparent"
      fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, root.working ? coreLevel.value : 0)
      PathSvg { path: root.inner }
    }
  }

  QtObject {
    id: coreLevel
    property real value: 0.35
  }

  SequentialAnimation {
    running: root.working && !Style.reduceMotion
    loops: Animation.Infinite
    onRunningChanged: if (!running) coreLevel.value = 0.35
    NumberAnimation { target: coreLevel; property: "value"; from: 0.12; to: 0.7; duration: Style.duration(650); easing.type: Easing.InOutSine }
    NumberAnimation { target: coreLevel; property: "value"; from: 0.7; to: 0.12; duration: Style.duration(650); easing.type: Easing.InOutSine }
  }
}
