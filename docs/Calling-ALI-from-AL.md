# Calling ALI from AL — full API reference

Detailed companion to [README section 5](../README.md#5-calling-ali-from-al).

For developers who want to embed ALI in their own extension: an AI tool, a job, a custom page.

- [Public objects](#public-objects)
- [Quick start](#quick-start)
- [Script shape and entry point](#script-shape-and-entry-point)
- [Compile, then run](#compile-then-run)
- [Reading diagnostics](#reading-diagnostics)
- [Reading the result](#reading-the-result)
- [Run options](#run-options)
- [Stored compiled script](#stored-compiled-script)
- [Syntax check only](#syntax-check-only)
- [Pitfalls](#pitfalls)

## Public objects

| Object | ID | Role |
|---|---|---|
| [`ALI Engine`](../AL-Interpreter/Runtime/ALIEngine.Codeunit.al) | codeunit 51111 | Compile, run, save/load compiled script, compile options |
| [`ALI Run Options`](../AL-Interpreter/Runtime/ALIRunOptions.Codeunit.al) | codeunit 51116 | Run options: exec mode, UI handling, security gates |
| [`ALI Diag Bag`](../AL-Interpreter/Foundation/ALIDiagBag.Codeunit.al) | codeunit 51101 | Compile diagnostics (errors, warnings, infos) |
| [`ALI Exec Result`](../AL-Interpreter/Runtime/ALIExecResult.Codeunit.al) | codeunit 51112 | Run outcome: success, error + position, return value, messages |
| `ALI Exec Mode`, `ALI Dialog Mode`, `ALI Interaction Mode`, `ALI Message Mode` | enums 51101, 51111, 51112, 51113 | Option values (see [Run options](#run-options)) |

`ALI Engine` and `ALI Run Options` are **`SingleInstance`**: settings persist for the whole session and are shared with every other caller (Script Editor, AI tool…). Set everything you depend on before each run.

## Quick start

```al
procedure RunScript(Source: Text): Text
var
    Engine: Codeunit "ALI Engine";
    RunOptions: Codeunit "ALI Run Options";
    Result: Codeunit "ALI Exec Result";
begin
    RunOptions.Reset();                                          // drop options left by another caller
    RunOptions.SetMode("ALI Exec Mode"::Simulation.AsInteger()); // roll back every DB write
    Engine.SetRequireOnRun(false);                               // first procedure = entry point

    Engine.CompileAndRun(Source, Result);
    exit(Result.ToText());   // 'OK -> 42 [12 statements, 3 ms]' or 'ERROR(3,5): ...'
end;
```

With this source:

```al
procedure Main(): Integer
var
    Cust: Record Customer;
begin
    Cust.SetRange(Blocked, Cust.Blocked::" ");
    exit(Cust.Count());
end;
```

## Script shape and entry point

| Shape | Example |
|---|---|
| Statement block | `Message('Hello');` — wrapped in an implicit `OnRun` |
| Procedure set | globals (`var ...`) + procedures + optional `trigger OnRun()` |
| Codeunit shell | `codeunit 50000 X { ... }` |

Entry point:

- **Default** (`Engine.SetRequireOnRun(false)`): the procedure named `OnRun`, else the **first declared** procedure. Declare the entry procedure first — a helper declared first would run with zero parameters.
- **Strict** (`Engine.SetRequireOnRun(true)`, used by the Script Editor): only `trigger OnRun()` qualifies; missing = error `ALI1000`.

The entry procedure/trigger may return a value (`trigger OnRun(): Integer`), available formatted in `Result.ResultText()`.

## Compile, then run

`CompileAndRun` is a shortcut. Split both steps to inspect warnings before running, or to keep the compiled script:

```al
procedure CompileThenRun(Source: Text): Text
var
    Diags: Codeunit "ALI Diag Bag";
    Engine: Codeunit "ALI Engine";
    Result: Codeunit "ALI Exec Result";
    Output: TextBuilder;
begin
    // Compile options — read at Compile time
    Engine.SetOptimize(false);
    Engine.SetRequireOnRun(false);
    Engine.SetVerbose(true);

    if not Engine.Compile(Source, Diags) then
        exit(Diags.ToText());              // every error at once

    if Diags.WarningCount() > 0 then
        Output.AppendLine(Diags.ToText()); // e.g. FlowField read without CalcFields

    Engine.RunCompiled(Result);            // runs the last compiled script
    Output.Append(Result.ToText());
    exit(Output.ToText());
end;
```

| Engine procedure | Effect |
|---|---|
| `Compile(Source, var Diags): Boolean` | Compiles; result kept in the engine |
| `RunCompiled(var Result): Boolean` | Runs the kept script; fails if none compiled |
| `CompileAndRun(Source, var Result): Boolean` | Both; on compile failure `Result` carries the first error |
| `Warmup()` | Optional, once per session (e.g. on page open): first run drops from ~600 ms to ~130 ms |

Compile options (`ALI Engine`):

| Setter | Default | Effect |
|---|---|---|
| `SetOptimize(Boolean)` | `false` | Precompute constant expressions, drop dead branches |
| `SetRequireOnRun(Boolean)` | `false` | Strict `trigger OnRun()` entry point |
| `SetVerbose(Boolean)` | `false` | Errors quote source line + caret + hint. Same as `RunOptions.SetVerbose` (either enables it) |

## Reading diagnostics

`ALI Diag Bag` collects all diagnostics and never stops at the first error.

| Procedure | Returns |
|---|---|
| `HasErrors()`, `ErrorCount()`, `WarningCount()`, `Count()` | Counters |
| `ToText()` | All diagnostics, one per line (verbose: + source line, caret, hint) |
| `ToJson()` | All diagnostics as JSON |
| `GetCode(i)`, `GetSeverity(i)`, `GetMessage(i)`, `GetLine(i)`, `GetColumn(i)`, `GetText(i)` | Entry `i` (1-based). Severity = `"ALI Severity"` ordinal: 0 Info, 1 Warning, 2 Error |

```al
for i := 1 to Diags.Count() do
    if Diags.GetSeverity(i) = "ALI Severity"::Error.AsInteger() then
        Log(StrSubstNo('%1 (%2,%3): %4', Diags.GetCode(i), Diags.GetLine(i), Diags.GetColumn(i), Diags.GetMessage(i)));
```

`RunOptions.SetHideDiagCodes(true)` drops the `ALI1234: ` prefix from texts (useful when the reader is an LLM).

## Reading the result

| `ALI Exec Result` procedure | Returns |
|---|---|
| `Succeeded()` | Run outcome |
| `ToText()` | One-line summary (`OK -> value [...]` / `ERROR(line,col): message [...]`) |
| `HasResult()`, `ResultText()`, `ResultTypeOrd()` | Entry procedure return value, formatted, and its `"ALI Type Kind"` ordinal |
| `ErrorMessage()`, `ErrorLine()`, `ErrorColumn()`, `ErrorSourceText()` | Runtime or compile error, script position, failing source line (verbose only) |
| `CollectedMessageCount()`, `GetCollectedMessage(i)` | Every `Message(...)` raised by the script |
| `RuntimeWarningCount()`, `GetRuntimeWarning(i)` | Runtime warnings (e.g. unscripted `Confirm`) |
| `StartDateTime()`, `EndDateTime()`, `DurationMs()`, `ExecutedStatements()` | Metrics |

```al
Engine.RunCompiled(Result);
if not Result.Succeeded() then
    Error('Script failed line %1: %2', Result.ErrorLine(), Result.ErrorMessage());
for i := 1 to Result.CollectedMessageCount() do
    Log(Result.GetCollectedMessage(i));
if Result.HasResult() then
    exit(Result.ResultText());
```

## Run options

Set on `ALI Run Options` **before** `Compile` / `RunCompiled`. `Reset()` restores all defaults.

```al
procedure ConfigureRun()
var
    RunOptions: Codeunit "ALI Run Options";
begin
    RunOptions.Reset();

    // Transaction
    RunOptions.SetMode("ALI Exec Mode"::Normal.AsInteger());

    // UI handling
    RunOptions.SetMessageMode("ALI Message Mode"::Log.AsInteger());
    RunOptions.SetDialogMode("ALI Dialog Mode"::Hide.AsInteger());
    RunOptions.SetInteractionMode("ALI Interaction Mode"::Default.AsInteger());

    // Scripted Confirm / StrMenu answers
    RunOptions.QueueConfirmAnswer(true);      // 1st Confirm() -> true
    RunOptions.QueueConfirmAnswer(false);     // 2nd Confirm() -> false
    RunOptions.SetDefaultConfirmAnswer(true); // every later Confirm() -> true
    RunOptions.SetDefaultStrMenuAnswer(2);    // every StrMenu() -> option 2

    // Capability / security gates
    RunOptions.SetAllowHttp(false);
    RunOptions.SetAllowProtectedWrite(false);
    RunOptions.SetApplyRecordSecurity(true);

    // Output
    RunOptions.SetVerbose(true);
    RunOptions.SetHideDiagCodes(false);
end;
```

**Exec mode** — `SetMode` (`ALI Exec Mode`)

| Value | Default | Behavior |
|---|---|---|
| `Normal` (0) | ✔ | Writes persist. Script `COMMIT` is real. A runtime error rolls back to the run start (or the last script `COMMIT`). |
| `Simulation` (1) | | Every DB write is rolled back at the end, even on success. `COMMIT` is ignored (in the script and in called objects). |

> ⚠️ In both modes the **caller's pending writes are committed** just before the run starts. Do not call ALI in the middle of a transaction you may need to roll back.

**Message** — `SetMessageMode` (`ALI Message Mode`). `Message`, `Error` and `Sleep` are always intercepted.

| Value | Default | Behavior |
|---|---|---|
| `Log` (0) | ✔ | Messages only collected in the result |
| `Show` (1) | | Collected **and** shown as a real `Message` when the session has a GUI |

**GuiAllowed** — `SetDialogMode` (`ALI Dialog Mode`)

| Value | Default | Script's `GuiAllowed()` |
|---|---|---|
| `Show` (0) | ✔ | Real `GuiAllowed()` of the host session |
| `Hide` (1) | | Always `false` — `if GuiAllowed then` blocks and `Dialog` windows are skipped |

**Confirm / StrMenu** — `SetInteractionMode` (`ALI Interaction Mode`)

| Value | Default | Behavior |
|---|---|---|
| `Default` (0) | ✔ | Scripted answer; without one, `Confirm` → `false` / `StrMenu` → `0` + warning |
| `Error` (1) | | Scripted answer; without one, runtime error |
| `Show` (2) | | Real `Confirm`/`StrMenu` dialog when the session has a GUI, else as `Default` |

Queued answers (`QueueConfirmAnswer`, `QueueStrMenuAnswer`) are consumed in order, then the default (`SetDefaultConfirmAnswer`, `SetDefaultStrMenuAnswer`) applies. `ClearConfirmAnswers()` / `ClearStrMenuAnswers()` empty the queues.

**Gates and output**

| Setter | Default | Effect |
|---|---|---|
| `SetAllowHttp(Boolean)` | `false` | Allow outbound `HttpClient` calls |
| `SetAllowProtectedWrite(Boolean)` | `false` | Allow writes to posted documents, ledger entries and registers |
| `SetApplyRecordSecurity(Boolean)` | `false` | Apply the application's record security filters on every table read |
| `SetVerbose(Boolean)` | `false` | Same as `Engine.SetVerbose` |
| `SetHideDiagCodes(Boolean)` | `false` | Omit `ALIxxxx:` codes in diagnostics / errors |

`Engine.SetAllowHttp`, `SetAllowProtectedWrite` and `SetApplyRecordSecurity` forward to `ALI Run Options` — call them **after** `RunOptions.Reset()`, never before.

## Stored compiled script

Skip compilation on later runs:

```al
// First run: compile and store
if Engine.Compile(Source, Diags) then
    StoreText(Engine.SaveCompiled());    // JSON text, '' if nothing compiled

// Later run, any session
if not Engine.LoadCompiled(StoredText) then   // false: incompatible build -> recompile
    Engine.Compile(Source, Diags);
Engine.RunCompiled(Result);
```

The stored text includes the script **and** every AL object it calls. Key it on a hash of source, ALI app version, preprocessor symbols and compile options, and offer a forced recompile for when called objects change.

## Syntax check only

`Engine.CheckDiagnostics(Source, Diags)`: fast check without producing a runnable script (`RunCompiled` fails afterwards). Called objects are checked by signature only. Use it for as-you-type checks; `Compile` before running.

## Pitfalls

- **Single instance.** Another caller may have left `SetRequireOnRun(true)`, verbose or Simulation on. Call `RunOptions.Reset()` and every `Engine.Set*` you rely on before each run.
- **Caller commit.** Running a script commits the caller's pending writes first.
- **Statement budget.** Runs abort after 10M executed statements by default (`RunOptions.SetStatementBudget`).
- **Entry point.** In default mode the first declared procedure runs; declare the entry procedure first.
- **Background sessions.** `Show` modes need a GUI session; in job queue / web service contexts they fall back to headless behavior.

The Script Editor page ([`ALCodeEditor/ALIScriptEditor.Page.al`](../AL-Interpreter/ALCodeEditor/ALIScriptEditor.Page.al)) is a complete reference caller: options from the stored script record, strict `OnRun`, stored compiled script, `Warmup` on open.
