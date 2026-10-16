import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Compact dictation indicator: a small mic + wave capsule centred just below
// the bar, with a one-line strip under it showing the words of the phrase
// being spoken. Sits on the Overlay layer so it stays above fullscreen
// windows, and never reaches the top-right notification column.
// State and live preview come from the dictate service via the voxtype shim;
// live mic levels come from levels.py while recording.
Item {
  id: root

  // Injected by the shell; gives the live bar size/visibility/position.
  property var shell: null

  property string state: "idle"
  property string preview: ""
  property string lastPreview: ""
  property string source: ""
  // "starting": the mic (e.g. a Bluetooth headset switching to hands-free)
  // is not delivering audio yet.
  readonly property bool starting: state === "starting"
  readonly property bool recording: state === "recording"
  readonly property bool listening: recording || starting
  readonly property bool transcribing: state === "transcribing"
  // Brief notice after the service reports a failed transcription.
  property bool failed: false
  readonly property bool showError: failed && !listening && !transcribing
  readonly property bool shown: listening || transcribing || failed
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  // ---- placement ------------------------------------------------------
  readonly property var bar: shell && shell.bar ? shell.bar : null
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property bool barHidden: bar ? bar.barHidden === true : false
  readonly property bool barTop: !bar || String(bar.position || "top") === "top"
  readonly property int topOffset: (barTop && !barHidden ? barSize : 0) + Style.space(4)
  // Screen chosen when the indicator appears; kept for the whole dictation
  // so the surface doesn't hop monitors (and get recreated) mid-sentence.
  property var targetScreen: null

  function focusedScreen() {
    var name = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  onShownChanged: if (shown) targetScreen = focusedScreen()

  // ---- sizes (Style.space scales with the shell font size) -------------
  readonly property int capH: Style.space(18)
  readonly property int padX: Style.space(6)
  readonly property int micSize: Style.space(10)
  readonly property int micGap: Style.space(5)
  readonly property int barCount: 12
  readonly property int barW: Style.space(2)
  readonly property int barGap: Style.space(1)
  readonly property int minH: Style.space(2)
  readonly property int maxH: Style.space(10)
  readonly property int waveW: barCount * barW + (barCount - 1) * barGap
  readonly property int stripH: Style.space(16)
  readonly property int stripPadX: Style.space(8)
  readonly property int stripMaxW: Style.space(330)
  // Width of Omarchy notification cards; the strip stays left of them.
  readonly property int notifyW: Style.space(380)

  readonly property color textColor: Color.popups.text

  // ---- levels ---------------------------------------------------------
  property var levels: []
  property real env: 0
  property real phase: 0

  function resetLevels() {
    var a = []
    for (var i = 0; i < barCount; i++) a.push(0)
    levels = a
    env = 0
  }

  // Gate out hiss, fast attack / ~120 ms decay, then a curve that lifts
  // quiet speech so the small bars still move.
  function pushLevel(v) {
    v = Math.max(0, Math.min(1, v))
    if (v < 0.06) v = 0
    env = v > env ? env + 0.6 * (v - env) : env * 0.80
    var a = levels.slice(1)
    a.push(Math.pow(env, 0.7))
    levels = a
  }

  // ---- strip text -----------------------------------------------------
  readonly property string stripText: showError ? "Transcription failed - try a shorter clip"
    : starting ? "Starting mic…"
    : recording && preview !== "" ? preview
    : transcribing ? lastPreview
    : ""
  readonly property real stripOpacity: showError || (recording && preview !== "") ? 1
    : starting ? 0.6
    : transcribing && lastPreview !== "" ? 0.55
    : 0
  readonly property color stripColor: showError ? Color.urgent : textColor

  onPreviewChanged: if (preview !== "") lastPreview = preview
  onListeningChanged: if (listening) { resetLevels(); failed = false; lastPreview = "" }
  onStateChanged: {
    if (state === "error") { failed = true; failTimer.restart() }
    if (state === "idle") lastPreview = ""
  }
  Timer { id: failTimer; interval: 3500; onTriggered: root.failed = false }
  Component.onCompleted: resetLevels()

  NumberAnimation on phase {
    running: root.transcribing
    from: 0; to: 2 * Math.PI; duration: 900; loops: Animation.Infinite
  }

  // ---- feeds ----------------------------------------------------------
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
    running: root.listening
    command: ["setpriv", "--pdeathsig", "TERM", "python3", "-I", root.pluginDir + "/levels.py", root.source]
    stdout: SplitParser {
      onRead: function(line) { root.pushLevel(parseFloat(line) || 0) }
    }
  }

  // Test hooks: omarchy-shell homedictation fake recording "some words"
  //             omarchy-shell homedictation dbg   (state + bar heights)
  IpcHandler {
    target: "homedictation"
    function fake(state: string, preview: string): string {
      root.state = state
      root.preview = preview
      return "ok"
    }
    function dbg(): string {
      var h = []
      for (var i = 0; i < waveRep.count; i++) h.push(waveRep.itemAt(i) ? waveRep.itemAt(i).height : -1)
      return JSON.stringify({ state: root.state, transcribing: root.transcribing, phase: root.phase, minH: root.minH, maxH: root.maxH, heights: h })
    }
  }

  // ---- surface --------------------------------------------------------
  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.shown || capsule.opacity > 0
    anchors { top: true; left: true; right: true }
    margins.top: root.topOffset
    // Fixed height: resizing a layer surface while visible can stretch
    // stale buffers.
    implicitHeight: root.capH + Style.space(3) + root.stripH + Style.space(4)
    color: "transparent"
    WlrLayershell.namespace: "home-dictation"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    // Mic + wave capsule.
    BorderSurface {
      id: capsule
      readonly property color edge: root.showError ? Color.urgent
        : root.recording ? Util.alpha(Color.urgent, 0.6)
        : root.transcribing ? Util.alpha(Color.accent, 0.5)
        : Color.popups.border
      width: 2 * root.padX + root.micSize + root.micGap + root.waveW
      height: root.capH
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.98)
      borderSpec: Border.surfaceSpec("popups", "border", edge, Math.max(1, Style.space(1)))
      radius: height / 2
      opacity: root.shown ? 1 : 0
      transform: Translate { y: root.shown ? 0 : -4; Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } } }
      Behavior on opacity { NumberAnimation { duration: root.shown ? 140 : 180; easing.type: Easing.OutCubic } }

      // Solid fill so video/subtitles never show through.
      Rectangle {
        anchors.fill: parent
        anchors.margins: Math.max(1, Style.space(1))
        radius: height / 2
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
      }

      Row {
        anchors.centerIn: parent
        spacing: root.micGap

        Text {
          id: mic
          width: root.micSize
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          text: root.showError ? "󰀦" : "󰍬"
          font.family: Style.font.family
          font.pixelSize: root.micSize
          color: root.showError || root.recording ? Color.urgent
            : root.transcribing ? Color.accent
            : root.textColor
          SequentialAnimation on opacity {
            running: root.listening; loops: Animation.Infinite
            NumberAnimation { to: root.starting ? 0.35 : 0.7; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            onRunningChanged: if (!running) mic.opacity = 1
          }
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.barGap
          Repeater {
            id: waveRep
            model: root.barCount
            Rectangle {
              id: waveBar
              required property int index
              anchors.verticalCenter: parent.verticalCenter
              width: root.barW
              radius: width / 2
              // Recording: live level. Transcribing: a travelling sine wave.
              height: root.recording ? root.minH + (root.maxH - root.minH) * (root.levels[index] || 0)
                : root.transcribing ? root.minH + (root.maxH - root.minH) * 0.35 * (1 + Math.sin(root.phase - index * 0.55))
                : root.minH
              color: root.showError ? Util.alpha(Color.urgent, 0.4)
                : root.transcribing ? Color.accent
                : root.starting ? Util.alpha(root.textColor, 0.25)
                : Util.alpha(root.textColor, 0.45 + 0.55 * (root.levels[index] || 0))
              // Only ease live levels (25 Hz); the transcribing wave changes
              // every frame, which would keep restarting the animation.
              Behavior on height { enabled: root.recording; NumberAnimation { duration: 40 } }

              // Starting: a highlight sweeps across the flat bars.
              SequentialAnimation on opacity {
                running: root.starting; loops: Animation.Infinite
                PauseAnimation { duration: waveBar.index * 60 }
                NumberAnimation { to: 1; duration: 200 }
                NumberAnimation { to: 0.4; duration: 300 }
                PauseAnimation { duration: (root.barCount - 1 - waveBar.index) * 60 + 100 }
                onRunningChanged: if (!running) waveBar.opacity = 1
              }
            }
          }
        }
      }
    }

    // One-line strip: live words (newest on the right), status messages.
    BorderSurface {
      id: strip
      readonly property real centreX: parent.width / 2
      width: Math.min(root.stripMaxW, Math.max(capsule.width, stripText.implicitWidth + 2 * root.stripPadX))
      height: root.stripH
      // Centred under the capsule, but never into the notification column.
      x: Math.max(0, Math.min(centreX - width / 2,
        parent.width - root.notifyW - Style.gapsOut - Style.space(5) - width))
      anchors.top: capsule.bottom
      anchors.topMargin: Style.space(3)
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.98)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
      radius: height / 2
      opacity: root.shown ? root.stripOpacity : 0
      Behavior on opacity { NumberAnimation { duration: root.stripOpacity > 0 ? 120 : 250 } }
      Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      Rectangle {
        anchors.fill: parent
        anchors.margins: Math.max(1, Style.space(1))
        radius: height / 2
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
      }

      Text {
        id: stripText
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.stripPadX
        anchors.rightMargin: root.stripPadX
        horizontalAlignment: implicitWidth <= width ? Text.AlignHCenter : Text.AlignLeft
        text: root.stripText
        textFormat: Text.PlainText
        elide: Text.ElideLeft
        maximumLineCount: 1
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        color: root.stripColor
      }
    }
  }
}
