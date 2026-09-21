// Style of one line in the ALI Script Editor Result pane. The page tags every line it writes
// with the value NAME ("ALI Script Editor".OutAt); the "ALI Code Editor" add-in paints it with
// CSS class ali-out-<name in lowercase> (ALICodeEditor.css). A new value needs its CSS rule.
enum 51116 "ALI Out Style"
{
    Extensible = false;

    value(0; Normal) { }
    value(1; Error) { }
    value(2; Warning) { }
    value(3; Info) { }
    value(4; Dim) { }
    value(5; Header) { }
    value(6; Ok) { }
}
