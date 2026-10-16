import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Floating dictation pill. Sits on the Overlay layer so it stays above
// fullscreen windows. State and the live preview of the phrase being spoken
// come from the dictate service via the voxtype shim; live mic levels come
// from levels.py while recording.
Item {
  id: root

  property string state: "idle"
  property string preview: ""
  property string source: ""
  // "starting": the mic (e.g. a Bluetooth headset switching to hands-free)
  // is not delivering audio yet. Shown like recording, with a wait label.
  readonly property bool starting: state === "starting"
  readonly property bool recording: state === "recording" || starting
  readonly property bool transcribing: state === "transcribing"
  // Brief red notice after the service reports a failed transcription.
  property bool failed: false
  readonly property bool shown: recording || transcribing || failed
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  readonly property int barCount: 28
  property var levels: []
  property int elapsed: 0

  readonly property color recColor: Color.urgent
  readonly property color textColor: Color.popups.text

  function resetLevels() {
    var a = []
    for (var i = 0; i < barCount; i++) a.push(0)
    levels = a
  }

  function pushLevel(v) {
    var a = levels.slice(1)
    a.push(Math.max(0, Math.min(1, v)))
    levels = a
  }

  onRecordingChanged: if (recording) { elapsed = 0; resetLevels(); failed = false }
  onStateChanged: if (state === "error") { failed = true; failTimer.restart() }
  Timer { id: failTimer; interval: 3500; onTriggered: root.failed = false }
  Component.onCompleted: resetLevels()

  Process {
    id: statusProc
    command: [Quickshell.env("HOME") + "/.local/bin/voxtype", "status", "--follow", "--format", "json"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var d = JSON.parse(line)
          root.state = String(d.alt || d.class || "idle")
          root.preview = String(d.preview || "")
          root.source = String(d.source || "")
        } catch (e) {}
      }
    }
    // Restart the follower if it ever exits.
    onRunningChanged: if (!running) restartTimer.start()
  }
  Timer { id: restartTimer; interval: 2000; onTriggered: statusProc.running = true }

  Process {
    running: root.recording
    command: ["setpriv", "--pdeathsig", "TERM", "python3", "-I", root.pluginDir + "/levels.py", root.source]
    stdout: SplitParser {
      onRead: function(line) { root.pushLevel(parseFloat(line) || 0) }
    }
  }

  Timer {
    interval: 1000; repeat: true; running: root.recording
    onTriggered: root.elapsed++
  }

  PanelWindow {
    visible: root.shown || card.opacity > 0
    anchors { bottom: true; left: true; right: true }
    implicitHeight: card.height + previewBox.height + Style.space(60)
    color: "transparent"
    WlrLayershell.namespace: "home-dictation"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    // Live preview of the words in the phrase being spoken. Single line,
    // elided on the left so the newest words stay visible.
    BorderSurface {
      id: previewBox
      readonly property bool active: root.state === "recording" && root.preview !== ""
      width: Math.min(Style.space(720), previewText.implicitWidth + Style.space(36))
      height: Style.space(40)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: card.top
      anchors.bottomMargin: Style.space(10)
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.98)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
      radius: Math.max(Style.cornerRadius, Style.space(12))
      opacity: active ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 140 } }
      Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      Rectangle {
        anchors.fill: parent
        anchors.margins: Math.max(1, Style.space(1))
        radius: Math.max(0, previewBox.radius - anchors.margins)
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
      }

      Text {
        id: previewText
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(18)
        anchors.rightMargin: Style.space(18)
        text: root.preview
        textFormat: Text.PlainText
        elide: Text.ElideLeft
        font.family: Style.font.family
        font.pixelSize: Style.font.baseSize + 1
        color: root.textColor
      }
    }

    BorderSurface {
      id: card
      width: Style.space(360)
      height: Style.space(52)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(24)
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.98)
      borderSpec: Border.surfaceSpec("popups", "border",
        (root.recording || (root.failed && !root.transcribing)) ? root.recColor : Color.popups.border, Math.max(1, Style.space(2)))
      radius: Math.max(Style.cornerRadius, height / 2)
      opacity: root.shown ? 1 : 0
      scale: root.shown ? 1 : 0.92
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      // Solid fill so video/subtitles never show through the pill.
      Rectangle {
        anchors.fill: parent
        anchors.margins: Math.max(1, Style.space(2))
        radius: Math.max(0, card.radius - anchors.margins)
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
      }

      // Recording: pulsing dot + mic, live waveform, timer.
      Row {
        visible: root.recording
        anchors.centerIn: parent
        spacing: Style.space(12)

        Item {
          width: Style.space(28); height: Style.space(28)
          anchors.verticalCenter: parent.verticalCenter
          Rectangle {
            anchors.centerIn: parent
            width: parent.width; height: width; radius: width / 2
            color: Util.alpha(root.recColor, 0.25)
            SequentialAnimation on scale {
              running: root.recording; loops: Animation.Infinite
              NumberAnimation { from: 0.8; to: 1.15; duration: 700; easing.type: Easing.InOutSine }
              NumberAnimation { from: 1.15; to: 0.8; duration: 700; easing.type: Easing.InOutSine }
            }
          }
          Text {
            anchors.centerIn: parent
            text: "󰍬"
            font.family: Style.font.family
            font.pixelSize: Style.space(18)
            color: root.recColor
          }
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(3)
          Repeater {
            model: root.barCount
            Rectangle {
              required property int index
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(4)
              radius: width / 2
              height: Math.max(Style.space(4), Style.space(30) * (root.levels[index] || 0))
              color: Util.alpha(root.textColor, 0.35 + 0.65 * (root.levels[index] || 0))
              Behavior on height { NumberAnimation { duration: 60 } }
            }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.starting ? "Starting mic…"
            : Math.floor(root.elapsed / 60) + ":" + ("0" + root.elapsed % 60).slice(-2)
          font.family: Style.font.family
          font.pixelSize: Style.font.baseSize
          font.bold: true
          color: root.textColor
        }
      }

      // Failed: warning glyph + message, auto-hides after a few seconds.
      Row {
        visible: root.failed && !root.recording && !root.transcribing
        anchors.centerIn: parent
        spacing: Style.space(10)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰀦"
          font.family: Style.font.family
          font.pixelSize: Style.space(18)
          color: root.recColor
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Transcription failed - try a shorter clip"
          font.family: Style.font.family
          font.pixelSize: Style.font.baseSize
          font.bold: true
          color: root.textColor
        }
      }

      // Transcribing: spinning arc + label + bouncing dots.
      Row {
        visible: root.transcribing
        anchors.centerIn: parent
        spacing: Style.space(12)

        Canvas {
          id: spinner
          width: Style.space(22); height: width
          anchors.verticalCenter: parent.verticalCenter
          property color arc: Color.accent
          onArcChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var r = width / 2 - 2
            ctx.lineWidth = 3
            ctx.lineCap = "round"
            ctx.strokeStyle = Util.alpha(root.textColor, 0.2)
            ctx.beginPath(); ctx.arc(width / 2, height / 2, r, 0, 2 * Math.PI); ctx.stroke()
            ctx.strokeStyle = arc
            ctx.beginPath(); ctx.arc(width / 2, height / 2, r, -Math.PI / 2, Math.PI * 0.9); ctx.stroke()
          }
          RotationAnimation on rotation {
            running: root.transcribing; loops: Animation.Infinite
            from: 0; to: 360; duration: 900
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Transcribing"
          font.family: Style.font.family
          font.pixelSize: Style.font.baseSize
          font.bold: true
          color: root.textColor
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          Repeater {
            model: 3
            Rectangle {
              required property int index
              width: Style.space(5); height: width; radius: width / 2
              color: Color.accent
              opacity: 0.3
              SequentialAnimation on opacity {
                running: root.transcribing; loops: Animation.Infinite
                PauseAnimation { duration: index * 160 }
                NumberAnimation { to: 1; duration: 240 }
                NumberAnimation { to: 0.3; duration: 240 }
                PauseAnimation { duration: (2 - index) * 160 }
              }
            }
          }
        }
      }
    }
  }
}
