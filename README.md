# ALI — AL Live Interpreter for Business Central

Write, check and run AL code **directly inside Business Central** — no VS Code, no publishing, no extension deployment. Complete AL compiler and interpreter written in pure AL: no .NET assembly, no DLL, no external service.

NB: most of this app was designed and developed with Anthropic Fable 5.1 and Opus 5.

## Contents

1. [Live code editor](#1-live-code-editor)
2. [Supported features](#2-supported-features)
3. [AL usage](#3-al-usage)
4. [Architecture](#4-architecture)

---

## 1. Live code editor

<!-- screenshot: editor overview -->

**AL Script Editor** page brings VS Code-like editing into the Business Central web client. Type AL, press **F5**, see result.

### Live syntax check

<!-- screenshot: live diagnostics -->

Code checked **as you type**, errors underlined in place and listed in the **Problems** panel. Real semantic checks against your database — unknown tables, fields, procedures, wrong argument types, invalid `var` arguments — not just keyword coloring.

- Syntax coloring, auto-indent, completion and hover for keywords, builtins, tables, fields, codeunit procedures and enums
- "Did you mean" suggestions on misspelled names
- Clickable result lines jump to source location

### Multi-tab

<!-- screenshot: tab strip -->

Several scripts open at once in tabs. New tab = scratch buffer; once named (inline rename), saved as stored script and auto-saved. Stored scripts reopen from script list.

### Compile & run options

<!-- screenshot: options page -->

| Option | Default | Effect |
|---|---|---|
| **Simulation / Normal** (toolbar toggle) | Simulation | Simulation rolls back every database write, even on success — safe on live data. Normal commits. |
| Verbose | Off | Errors quote source line with caret and plain-language hint |
| Optimize | Off | Precompute constant expressions, drop dead branches |
| Allow HTTP | Off | Permit outbound `HttpClient` calls |
| Allow protected table write | Off | Permit writes to posted / ledger tables |
| Apply record security filters | Off | Script only sees records user is allowed to see |
| Show record operation counts | Off | List record operations performed by run |
| Message handler | Log | Log messages in result, or also show them |
| Confirm / StrMenu handler | Default | Scripted answer (else `false` / `0` + warning), raise error, or show real dialog |
| Dialog (GuiAllowed) | Show | Real `GuiAllowed`, or always `false` to simulate headless session |
| Preprocessor symbols | None | Define symbols for `#if` / `#endif` blocks |

Compiled script cached with it: unchanged script re-runs without compiling. **Force run** recompiles after called objects change.

### AI friendly

Built to be driven by LLMs as much as by humans:

- **Safe by default** — Simulation mode, record security filters, HTTP and protected-write gates let AI agents run code on real data without side effects.
- **Errors built for self-correction** — all errors reported at once, with source line, caret, hint and "did you mean". Common C#/JavaScript slips (`==`, `&&`, `"text"`, `;` before `else`, `String`/`int`) get their AL spelling in the hint.
- **Warnings for classic mistakes** — e.g. FlowField read without `CalcFields`.
- **Callable from AL** — small public API ([AL usage](#3-al-usage)): any AL code, AI tools included, compiles and runs a script and reads back messages, return value and errors as text or JSON.

### Performance

> ⚠️ **Slower than native AL — expect about 15× run time** on typical business logic (loops, sub procedures, text and collection work). Use for ad-hoc scripts, data fixes, investigations and AI-generated code, not as replacement for compiled extensions.

Why: interpreter itself written in AL, so each script statement costs several AL statements. Database work not slowed — reads, writes, filters and table triggers executed by platform as in native code. Overhead sits on surrounding logic: SQL-heavy scripts (few big `FindSet` / `ModifyAll`) come much closer to native speed than tight in-memory loops.

Script compiled once, everything resolved up front. Since AL procedure calls are expensive, hottest operations are **inlined into main execution loop** — deliberately ugly interpreter code, traded for acceptable speed.

> **Room left for optimization.** Inlining *everything* into execution loop and merging all runtime codeunits (records, text, JSON, XML, HTTP…) into one giant codeunit would bring execution much closer to native speed. Not done on purpose: tens of thousands of lines in one codeunit, unreadable and practically unmaintainable.

**Benchmark** action on options page measures it on your own data: same workload run as native AL and through ALI ([ALIBenchmark.Codeunit.al](ALCodeEditor/ALIBenchmark.Codeunit.al)), both returning a checksum that must match. Per customer, read-only:

- `SetLoadFields` + `FindSet`/`Next` on Customer
- text: `UpperCase`, `DelChr`, `CopyStr`, concatenation, `StrLen`
- char arithmetic loop over customer number (`s[i]`)
- decimal `Round`, date `Date2DMY`, `mod`
- `Dictionary of [Code, Integer]` count per country, `List of [Text]`
- three sub procedure calls with by-value parameters

Warm-up pass runs first so neither side pays SQL cache warm-up. Compile time reported separately.

| Customers | Native AL | ALI | ALI compile | Ratio |
|---|---|---|---|---|
| 100 000 | 706 ms | 11 113 ms | 16 ms | ×15.7 |

---

## 2. Supported features

Built to match native AL compiler (alc.exe) and runtime behavior as closely as possible.

- ✅ supported, behaves like native AL
- 🔶 recognized — compiles, but reports clear "not implemented yet" error
- ❌ not supported

Reference: [AL data types and methods](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/methods-auto/library).

### 2.1 Data types

| Data type | Status | Notes |
|---|---|---|
| Integer, BigInteger, Decimal, Boolean, Byte, Char | ✅ | char arithmetic, `s[i]` read/write |
| Text / Text[n], Code[n], Label | ✅ | length enforced, Code upper-cased |
| Option, Enum | ✅ | `Enum::X::Y`, `Format` |
| System option types (`TextEncoding`, `IsolationLevel`, `SecurityFilter`, `ClientType`, `TransactionType`, `DataClassification`, `ErrorType`, `PageStyle`, `Verbosity`, `FieldClass`, `FieldType`) | ✅ | as values and variable types |
| Date, Time, DateTime, Duration, DateFormula | ✅ | native arithmetic, `CalcDate`, `Evaluate` |
| Guid | ✅ | |
| Array (`array[N] of`) | ✅ | multidimensional, `ArrayLen` / `CopyArray` / `CompressArray` |
| Variant | ✅ | `Is*` predicates |
| Record, temporary Record | ✅ | table triggers and `OnValidate` run natively |
| RecordRef, FieldRef, KeyRef | ✅ | full native surface (§2.4) |
| RecordId | ✅ | |
| List of [T], Dictionary of [K,V] | ✅ | |
| TextBuilder, BigText, SecretText | ✅ | |
| InStream / OutStream, Blob fields | ✅ | optional `TextEncoding` |
| HttpClient & Http* family | ✅ | requires *Allow HTTP* |
| JsonObject / JsonArray / JsonToken / JsonValue | ✅ | |
| Xml* (all 16 types) | ✅ | |
| Dialog | ✅ | |
| Codeunit variables (`MyCU.Proc()`), `Codeunit.Run` | ✅ | your own codeunits' procedures compiled on the fly; `Codeunit.Run` executes natively |
| Table & tableextension procedures (`Rec.MyProc()`) | ✅ | object global variables included |
| Event publishers / subscribers | ✅ | raising event runs every active subscriber; `IsHandled` pattern works |
| Native codeunits (Type Helper, Base64 Convert, Math, Encoding, Environment Information, Language, Cryptography Management, Data Compression, Temp Blob, Regex) | ✅ | called natively (§2.10) |
| Media / MediaSet fields | 🔶 | read ✅, import / insert / remove ❌ |
| ErrorInfo, File / FileUpload | 🔶 | |
| DotNet | ❌ | procedures using DotNet blocked; rest of object still works |
| Page, Report, Query, XmlPort, Notification, TestPage variables | ❌ | static `Page.Run` / `Report.Run` ✅ |
| IsolatedStorage, TaskScheduler, Session, NavApp, ModuleInfo, DataTransfer, FilterPageBuilder, NumberSequence, … | ❌ | |

### 2.2 Statements & language

All ✅:

- Assignment `:=`, compound `+=` `-=` `*=` `/=`
- `if/then/else`, `case` (value lists, ranges), `for/to/downto`, `while`, `repeat/until`, `foreach` (List, JsonArray, XmlNodeList, XmlAttributeCollection, Dictionary keys), `exit`, `break`
- All operators with native precedence; `and`/`or` evaluated eagerly as in native AL
- Procedures: by-value and `var` parameters, recursion, overloading, named return values, paren-less calls (`MyProc;`, `x := Rec.Count`)
- Record parameters, by value and `var`, temporary records
- `[TryFunction]`, `GetLastErrorText`
- `Commit()`
- `System.` qualifier
- Implicit conversions: numeric, `Enum ↔ Option`, `Char → Text`
- `with` rejected (NoImplicitWith)

### 2.3 Record methods

All ✅ unless noted:

`Init`, `Reset`, `Insert`, `Modify`, `Delete`, `DeleteAll`, `ModifyAll`, `Rename`, `Truncate`, `Get` (incl. RecordId), `GetBySystemId`, `Find`, `FindFirst`, `FindLast`, `FindSet`, `Next`, `Count`, `CountApprox`, `IsEmpty`, `SetRange`, `SetFilter`, `GetFilter(s)`, `CopyFilter(s)`, `SetRecFilter`, `GetRangeMin/Max`, `GetView/SetView`, `GetPosition/SetPosition`, `HasFilter`, `FilterGroup`, `SetCurrentKey`, `CurrentKey`, `Ascending`, `KeyCount`, `CalcFields`, `CalcSums`, `SetAutoCalcFields`, `SetLoadFields`, `AddLoadFields`, `LoadFields`, `AreFieldsLoaded`, `Copy`, `TransferFields`, `Validate`, `TestField`, `FieldError`, `Mark`, `ClearMarks`, `MarkedOnly`, `LockTable`, `ReadIsolation`, `ReadConsistency`, `RecordLevelLocking`, `SecurityFiltering`, `SetPermissionFilter`, `ReadPermission/WritePermission`, `ChangeCompany`, `CurrentCompany`, `IsTemporary`, `RecordId`, `TableName`, `TableCaption`, `FieldName`, `FieldCaption`, `FieldCount`, `FieldExist`, `AddLink`, `DeleteLink(s)`, `CopyLinks`, `HasLinks`.

❌ `FieldActive`, `FieldNo`, `Relation`, `Consistent`, `SetBaseLoadFields`.

**Record security** (option): every table read restricted to records user is allowed to see; script cannot remove these filters.

### 2.4 RecordRef / FieldRef / KeyRef

- **RecordRef** ✅ — `Open` (by id, or by table name as extension), `Close`, `Number`, `Name`, `Caption`, `GetTable`, `SetTable`, `Duplicate`, `Field` (by number or name), `FieldIndex`, `KeyIndex`, `FieldExist`, `System*No`, plus every Record method above and field-number forms (`SetRange`, `SetFilter`, `Validate`, `CalcFields`, `SetLoadFields`, …).
- **FieldRef** ✅ — `Value` (get/set), `Validate`, `SetRange`, `SetFilter`, `GetFilter`, `GetRangeMin/Max`, `CalcField`, `CalcSum`, `TestField`, `FieldError`, `Name`, `Number`, `Caption`, `Length`, `Active`, `Relation`, `Class`, `Type`, `OptionCaption`, `OptionMembers`, enum helpers, `IsOptimizedForTextSearch`, `Record`. `Value` on Blob / Media fields ❌.
- **KeyRef** ✅ — `Active`, `FieldCount`, `FieldIndex`, `Record`.
- Chaining works: `RRef.Field(3).Value := x`, `RRef.KeyIndex(1).FieldIndex(1).Name`.

### 2.5 Text

✅ `CopyStr`, `StrLen`, `MaxStrLen`, `StrPos`, `StrSubstNo`, `Format`, `LowerCase`, `UpperCase`, `DelChr`, `ConvertStr`, `PadStr`, `IncStr`, `SelectStr`, `Evaluate`, `DelStr`, `InsStr`, `StrCheckSum`, and instance methods `Contains`, `StartsWith`, `EndsWith`, `IndexOf`, `LastIndexOf`, `IndexOfAny`, `Replace`, `Split`, `Substring`, `ToLower`, `ToUpper`, `Trim`, `TrimStart`, `TrimEnd`, `PadLeft`, `PadRight`, `Remove`, `s[i]`.

### 2.6 Collections & builders

- **List** ✅ `Add`, `AddRange`, `Get`, `Set`, `Count`, `Contains`, `IndexOf`, `Insert`, `Remove`, `RemoveAt`, `RemoveRange`, `GetRange`, `Reverse` — ❌ `ToArray`
- **Dictionary** ✅ `Add`, `Set`, `Get`, `ContainsKey`, `Remove`, `Count`, `Keys`, `Values`
- **TextBuilder** ✅ full surface
- **BigText** ✅ `AddText`, `GetSubText`, `Length`, `TextPos`, `Read`, `Write`
- **SecretText** ✅ `IsEmpty`, `Unwrap`, `SecretStrSubstNo`
- **Media / MediaSet** ✅ `MediaId`, `HasValue`, `ExportStream`, `Count`, `Item` — ❌ `ImportStream`, `Insert`, `Remove`

### 2.7 Streams

✅ `WriteText`, `WriteLine`, `ReadText`, `Write`, `Read` (typed binary I/O), `EOS`, `Length`, `Position`, `ResetPosition`, `CopyStream`.

### 2.8 HTTP, JSON, XML

- **Http** ✅ `HttpClient` (`Get`, `Post`, `Put`, `Delete`, `Send`, `SetBaseAddress`, `Timeout`, `DefaultRequestHeaders`), `HttpRequestMessage`, `HttpResponseMessage`, `HttpContent`, `HttpHeaders`. Certificates / auth helpers ❌.
- **Json** ✅ full `JsonObject` / `JsonArray` / `JsonToken` / `JsonValue` surface, typed getters included (`GetText`, `GetInteger`, `GetObject`, …), `SelectToken`, `Clone`, `Keys`. JsonArray stays 0-based like native.
- **Xml** ✅ full documented surface of all 16 Xml types: create / read / write (text and streams), XPath `SelectNodes` / `SelectSingleNode` with namespaces, attributes, navigation.

### 2.9 System functions

| ✅ | 🔶 | ❌ |
|---|---|---|
| `Abs`, `Round`, `Power`, `Random`, `Randomize`, `Today`, `Time`, `CurrentDateTime`, `WorkDate`, `CalcDate`, `Date2DMY`, `Date2DWY`, `DMY2Date`, `DWY2Date`, `CreateDateTime`, `DT2Date`, `DT2Time`, `ClosingDate`, `NormalDate`, `RoundDateTime`, `Evaluate`, `Format`, `Clear`, `ClearAll`, `GetLastErrorText`, `ClearLastError`, `GetLastErrorCallStack`, `ArrayLen`, `CopyArray`, `CompressArray`, `Message`, `Error`, `Confirm`, `StrMenu`, `Sleep`, `GuiAllowed`, `CompanyName`, `UserId`, `UserSecurityId`, `SessionId`, `CreateGuid`, `IsNullGuid`, `GetUrl`, `GlobalLanguage`, `WindowsLanguage`, `SelectLatestVersion`, `CurrentClientType`, `CurrentExecutionMode`, `CopyStream`, `Variant2Date`, `Variant2Time`, `DaTi2Variant`, `Codeunit.Run`, `Page.Run`, `Report.Run`, `DownloadFromStream`, `UploadIntoStream`, `Database::` / `Codeunit::` / `Enum::` ids | `CurrReport`, `CurrPage`, `CurrFieldNo`, `Hyperlink`, `LogMessage`, `FeatureTelemetry`, `Download`, `Upload`, `FileExists`, `ErrorInfo` | Encryption functions, error-collection functions, `IsNull`, `GetDotNetType`, `ApplicationPath`, `TemporaryPath`, `CaptionClassTranslate`, `GetDocumentUrl` |

`Message` / `Error` captured in run result; `Confirm` / `StrMenu` answers scriptable.

### 2.10 Native codeunits

Called natively on real object, so their DotNet-based implementation works:

| Codeunit | Coverage |
|---|---|
| Type Helper | URL/HTML encoding, date/decimal formatting, UTC helpers, `IsNumeric`, `TextDistance`, bitwise ops, … |
| Base64 Convert | `ToBase64`, `ToBase64Url`, `FromBase64` (all overloads) |
| Math | all procedures |
| Encoding | `Convert` |
| Data Compression | ZIP and GZip (create, open, extract, add, remove entries) |
| Temp Blob | streams, `HasValue`, `Length`, from/to record and field |
| Environment Information | `IsProduction`, `IsSandbox`, `IsSaaS`, `IsOnPrem`, environment name / settings, … |
| Language | language / culture lookups and overrides |
| Cryptography Management | hashing, keyed hashes, `SignData`, `VerifyData` |
| Regex | `IsMatch`, `Match`, `Replace`, `Split`, `Escape`, groups & captures |

### 2.11 Diagnostics

- All errors reported at once, with line and column
- Verbose mode: source line, caret and hint under each error; runtime errors explain 1-based vs 0-based indexes, missing dictionary keys, …
- "Did you mean" for unknown methods, fields, tables and codeunits
- No error cascade after unknown call
- Warning for FlowField read without `CalcFields`
- Error codes can be hidden for cleaner output

---

## 3. AL usage

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
- [Reference hosts](#reference-hosts)

---

### Public objects

| Object | ID | Role |
|---|---|---|
| [`ALI Engine`](Runtime/ALIEngine.Codeunit.al) | codeunit 51029 | Compile, run, save/load compiled script, compile options |
| [`ALI Run Options`](Runtime/ALIRunOptions.Codeunit.al) | codeunit 51035 | Run options: exec mode, UI handling, security gates |
| [`ALI Diag Bag`](Foundation/ALIDiagBag.Codeunit.al) | codeunit 51008 | Compile diagnostics (errors, warnings, infos) |
| [`ALI Exec Result`](Runtime/ALIExecResult.Codeunit.al) | codeunit 51030 | Run outcome: success, error + position, return value, messages |
| `ALI Exec Mode`, `ALI Dialog Mode`, `ALI Interaction Mode`, `ALI Message Mode` | enums 51004, 51015–51017 | Option values (see [Run options](#run-options)) |

`ALI Engine` and `ALI Run Options` are **`SingleInstance`**: settings persist for the whole session and are shared with every other host (Script Editor, AI tool…). Set everything you depend on before each run.

---

### Quick start

```al
procedure RunScript(Source: Text): Text
var
    Engine: Codeunit "ALI Engine";
    RunOptions: Codeunit "ALI Run Options";
    Result: Codeunit "ALI Exec Result";
begin
    RunOptions.Reset();                                          // drop options left by another host
    RunOptions.SetMode("ALI Exec Mode"::Simulation.AsInteger()); // roll back every DB write
    Engine.SetRequireOnRun(false);                               // first procedure = entry point

    Engine.CompileAndRun(Source, Result);
    exit(Result.ToText());   // 'OK -> 42 [12 statements, 3 ms]' or 'ERROR(3,5): ...'
end;
```

With source:

```al
procedure Main(): Integer
var
    Cust: Record Customer;
begin
    Cust.SetRange(Blocked, Cust.Blocked::" ");
    exit(Cust.Count());
end;
```

---

### Script shape and entry point

| Shape | Example |
|---|---|
| Statement block | `Message('Hello');` — wrapped in implicit `OnRun` |
| Procedure set | globals (`var ...`) + procedures + optional `trigger OnRun()` |
| Codeunit shell | `codeunit 50000 X { ... }` |

Entry point:

- **Default** (`Engine.SetRequireOnRun(false)`): procedure named `OnRun`, else **first declared** procedure. Declare entry procedure first — a helper declared first runs with zero parameters.
- **Strict** (`Engine.SetRequireOnRun(true)`): only `trigger OnRun()` qualifies; missing = error `ALI1000`.

Entry procedure/trigger may return a value (`trigger OnRun(): Integer`), returned formatted in `Result.ResultText()`.

---

### Compile, then run

`CompileAndRun` is a shortcut. Split both steps to inspect warnings before running or to keep compiled script:

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

    Engine.RunCompiled(Result);            // runs last compiled script
    Output.Append(Result.ToText());
    exit(Output.ToText());
end;
```

| Engine procedure | Effect |
|---|---|
| `Compile(Source, var Diags): Boolean` | Compiles; result kept in engine |
| `RunCompiled(var Result): Boolean` | Runs kept script; fails if none compiled |
| `CompileAndRun(Source, var Result): Boolean` | Both; on compile failure `Result` carries first error |
| `Warmup()` | Optional, once per session (e.g. on page open): first run ~600 ms → ~130 ms |

#### Compile options (`ALI Engine`)

| Setter | Default | Effect |
|---|---|---|
| `SetOptimize(Boolean)` | `false` | Precompute constant expressions, drop dead branches |
| `SetRequireOnRun(Boolean)` | `false` | Strict `trigger OnRun()` entry point |
| `SetVerbose(Boolean)` | `false` | Errors quote source line + caret + hint. Same as `RunOptions.SetVerbose` (either enables it) |

---

### Reading diagnostics

`ALI Diag Bag` collects all diagnostics, never stops at first error.

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

`RunOptions.SetHideDiagCodes(true)` drops `ALI1234: ` prefix from texts (useful for LLM hosts).

---

### Reading the result

| `ALI Exec Result` procedure | Returns |
|---|---|
| `Succeeded()` | Run outcome |
| `ToText()` | One-line summary (`OK -> value [...]` / `ERROR(line,col): message [...]`) |
| `HasResult()`, `ResultText()`, `ResultTypeOrd()` | Entry procedure return value, formatted, and its `"ALI Type Kind"` ordinal |
| `ErrorMessage()`, `ErrorLine()`, `ErrorColumn()`, `ErrorSourceText()` | Runtime or compile error, script position, failing source line (verbose only) |
| `CollectedMessageCount()`, `GetCollectedMessage(i)` | Every `Message(...)` raised by script |
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

---

### Run options

Set on `ALI Run Options` **before** `Compile`/`RunCompiled`. `Reset()` restores all defaults below.

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
    RunOptions.QueueConfirmAnswer(true);     // 1st Confirm() -> true
    RunOptions.QueueConfirmAnswer(false);    // 2nd Confirm() -> false
    RunOptions.SetDefaultConfirmAnswer(true); // every later Confirm() -> true
    RunOptions.SetDefaultStrMenuAnswer(2);   // every StrMenu() -> option 2

    // Capability / security gates
    RunOptions.SetAllowHttp(false);
    RunOptions.SetAllowProtectedWrite(false);
    RunOptions.SetApplyRecordSecurity(true);

    // Output
    RunOptions.SetVerbose(true);
    RunOptions.SetHideDiagCodes(false);
end;
```

#### Exec mode — `SetMode` (`ALI Exec Mode`)

| Value | Default | Behavior |
|---|---|---|
| `Normal` (0) | ✔ | Writes persist. Script `COMMIT` is real. Runtime error rolls back to run start (or last script `COMMIT`). |
| `Simulation` (1) | | Every DB write rolled back at end, even on success. `COMMIT` ignored (script and called objects). |

> ⚠️ In both modes **caller's pending writes are committed** just before run starts. Do not call ALI mid-transaction you may need to roll back.

#### Message — `SetMessageMode` (`ALI Message Mode`)

`Message`, `Error` and `Sleep` always intercepted.

| Value | Default | Behavior |
|---|---|---|
| `Log` (0) | ✔ | Messages only collected in result |
| `Show` (1) | | Collected **and** shown as real `Message` when session has GUI |

#### GuiAllowed — `SetDialogMode` (`ALI Dialog Mode`)

| Value | Default | Script's `GuiAllowed()` |
|---|---|---|
| `Show` (0) | ✔ | Real `GuiAllowed()` of host session |
| `Hide` (1) | | Always `false` — `if GuiAllowed then` blocks and `Dialog` windows skipped |

#### Confirm / StrMenu — `SetInteractionMode` (`ALI Interaction Mode`)

| Value | Default | Behavior |
|---|---|---|
| `Default` (0) | ✔ | Scripted answer; without one, `Confirm` → `false` / `StrMenu` → `0` + warning |
| `Error` (1) | | Scripted answer; without one, runtime error |
| `Show` (2) | | Real `Confirm`/`StrMenu` dialog when session has GUI, else as `Default` |

Queued answers (`QueueConfirmAnswer`, `QueueStrMenuAnswer`) consumed in order, then default (`SetDefaultConfirmAnswer`, `SetDefaultStrMenuAnswer`) applies. `ClearConfirmAnswers()` / `ClearStrMenuAnswers()` empty queues.

#### Gates and output

| Setter | Default | Effect |
|---|---|---|
| `SetAllowHttp(Boolean)` | `false` | Allow outbound `HttpClient` calls |
| `SetAllowProtectedWrite(Boolean)` | `false` | Allow writes to posted/ledger tables |
| `SetApplyRecordSecurity(Boolean)` | `false` | Apply `TOO Record Security Filters` on every table read (AI hosts) |
| `SetVerbose(Boolean)` | `false` | Same as `Engine.SetVerbose` |
| `SetHideDiagCodes(Boolean)` | `false` | Omit `ALIxxxx:` codes in diagnostics / errors |

`Engine.SetAllowHttp`, `SetAllowProtectedWrite` and `SetApplyRecordSecurity` forward to `ALI Run Options` — call them **after** `RunOptions.Reset()`, never before.

---

### Stored compiled script

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

Stored text includes script **and** every AL object it calls. Key it on a hash of source, app version and compile options, and offer forced recompile when called objects change.

---

### Syntax check only

`Engine.CheckDiagnostics(Source, Diags)`: fast check without producing a runnable script (`RunCompiled` fails afterwards). Called objects checked by signature only. Use for as-you-type checks; `Compile` before running.

---

### Pitfalls

- **Single instance.** Another host may have left `SetRequireOnRun(true)`, verbose or Simulation on. Call `RunOptions.Reset()` and every `Engine.Set*` you rely on before each run.
- **Caller commit.** Running a script commits caller's pending writes first.
- **Statement budget.** Runs abort after 100M executed statements.
- **Entry point.** In default mode first declared procedure runs; declare entry procedure first.
- **Background sessions.** `Show` modes need GUI session; in job queue / web service they fall back to headless behavior.

---

### Reference hosts

| Host | File | Setup |
|---|---|---|
| AI tool `Run AL Code` | [`ECA AI/.../RunALCode.Codeunit.al`](../../ECA%20AI/Codeunit/AI%20Tools/Code/RunALCode.Codeunit.al) | Simulation, verbose, hidden codes, record security on, HTTP on, first-procedure entry |
| Script Editor | [`ALCodeEditor/ALIScriptEditor.Page.al`](ALCodeEditor/ALIScriptEditor.Page.al) | Options from stored script record, strict `OnRun`, stored compiled script, `Warmup` on open |

---

## 4. Architecture

Pure-AL compiler pipeline + register-bytecode interpreter, following native AL compiler behavior closely. Technical details below.

- [Folder layout](#folder-layout)
- [4.1 Compilation pipeline](#41-compilation-pipeline)
- [4.2 Core representation: struct-of-arrays](#42-core-representation-struct-of-arrays)
- [4.3 Lexer](#43-lexer)
- [4.4 Parser](#44-parser)
- [4.5 Binder](#45-binder-semantic-phase)
- [4.6 Method dispatch model](#46-method-dispatch-model)
- [4.7 Paren-less calls](#47-paren-less-calls)
- [4.8 Optimizer](#48-optimizer-optional)
- [4.9 Lowerer + module](#49-lowerer--module)
- [4.10 Interpreter](#410-interpreter)
- [4.11 JSON opcode extension](#411-json-opcode-extension)
- [4.12 Performance model](#412-performance-model)
- [4.13 Guarantees](#413-guarantees)

---

### Folder layout

| Folder | Content |
|---|---|
| [`Foundation/`](Foundation/) | Shared enums (`TokenKind`, `NodeKind`, `Opcode`, `TypeKind`, run modes…), token table, diagnostics bag (`ALI Diag Bag`), capacity constants (`ALI Limits`) |
| [`Frontend/`](Frontend/) | Lexer, parser, flat AST store, preprocessor symbols |
| [`Semantic/`](Semantic/) | Binder, symbol table, type rules, builtin/object registries, record & option metadata, optimizer passes |
| [`Runtime/`](Runtime/) | Engine facade, run options, exec result, lowerer, module, interpreter and per-family runtimes (Record, Json, Xml, Http, List, Dictionary, Stream, Native codeunits…) |
| [`ALCodeEditor/`](ALCodeEditor/) | Script Editor page + control add-in (live diagnostics, API catalog, run options page) |
| [`StoredALScript/`](StoredALScript/) | `ALI Stored Script` table (source + stored bytecode) and list page |
| [`Test/`](Test/) | Test codeunits per pipeline stage and test objects (tables, pages, events) |

---

### 4.1 Compilation Pipeline

```
Source
 → Lexer        → Token Store + Diags
 → Parser       → Flat AST + Diags
 → Binder       → Symbols, Types, Slots + Diags
 → Optimizer    → Rewritten AST (optional)
 → Lowerer      → Module (typed register bytecode)
 → Interpreter  → Exec Result
```

Public API: see [AL usage](#3-al-usage). Engine mapping: `Compile` = full pipeline, Module kept for `RunCompiled`; `CheckDiagnostics` = lexer → parser → binder only, called objects harvested for signatures only, no Module; `SaveCompiled` / `LoadCompiled` = Module serialized as JSON; `Warmup` instantiates pipeline once per session.

- All stages communicate via **flat data stores (var codeunits)**.
- Diagnostics are **collect-all**; errors propagate via `ErrorType`.
- Execution runs **lowered bytecode (not AST)** → "compile heavy, run fast".
- Calls to real AL objects (codeunits, tables, pages…) are resolved by [`ALI Object Registry`](Semantic/ALIObjectRegistry.Codeunit.al), which harvests the object source and binds it together with the script.

---

### 4.2 Core Representation: Struct-of-Arrays

Due to AL constraints (no heap objects/pointers):

- All structures = **parallel arrays indexed by int handles**
- Compile-time: `List of [T]`
- Runtime: **fixed arrays** (sealed at `LoadModule`)
- Limits enforced via [`ALI Limits`](Foundation/ALILimits.Codeunit.al)

Enums (`TokenKind`, `NodeKind`, `Opcode`, etc.) are **dense, append-only ordinals** → stable serialization.

---

### 4.3 Lexer

File: [`Frontend/ALILexer.Codeunit.al`](Frontend/ALILexer.Codeunit.al)

Single-pass scanner over `Text`.

Outputs **Token Table**:

- Columns: `Kind`, `Pos`, `Len`, `Line`, `Col`, `ValueIdx`
- Separate literal pools (int, decimal, text, datetime…)

Key features:

- **Identifier interning** (case-insensitive → int IDs)
- Contextual keywords
- Full AL literal/operator support
- Line offsets stored once (used by diagnostics)

---

### 4.4 Parser

Files: [`Frontend/ALIParser.Codeunit.al`](Frontend/ALIParser.Codeunit.al), [`Frontend/ALIParseCtx.Codeunit.al`](Frontend/ALIParseCtx.Codeunit.al), [`Frontend/ALIParserExpr.Codeunit.al`](Frontend/ALIParserExpr.Codeunit.al)

Recursive descent → **flat AST (CSR layout)**:

- Node columns: `Kind`, `Token`, `FirstChild`, `ChildCount`, `Extra`
- Missing nodes use sentinel (keeps indexing stable)

Key behaviors:

- **Pratt expression parsing** with native AL precedence quirks
- Exact **if/else semicolon binding rule**
- Error recovery: token insertion + panic resync
- Nesting-depth guard (prevents AL stack overflow)

Accepted units:

- Statement block (wrapped in `OnRun`)
- Procedure set (+ optional globals, + an optional top-level `trigger OnRun()`)
- Codeunit shell

**Entry point:** the proc named `OnRun`, else the first declared proc. With `"ALI Engine".SetRequireOnRun(true)` (the Script Editor) only `trigger OnRun()` qualifies and its absence is `ALI1000`. Unlike native AL, a trigger may declare a return value (`trigger OnRun(): Integer`, `trigger OnRun() Msg: Text`), parsed exactly like a procedure's.

**Stored bytecode:** `"ALI Engine".SaveCompiled()` / `LoadCompiled()` serialize the Module (`"ALI Module".Serialize`, JSON). The only session-scoped operand, `OPT_TO_TEXT`'s option-set id, is stored by spelling and re-interned on load (`"ALI Option Meta".DescribeSet` / `InternDescribed`). Serialized Module embeds harvested source of every called object; Script Editor keys it on SHA-256 of source + app version + compile options (`CompiledHash` in [`ALIScriptEditor.Page.al`](ALCodeEditor/ALIScriptEditor.Page.al)).

---

### 4.5 Binder (Semantic Phase)

File: [`Semantic/ALIBinder.Codeunit.al`](Semantic/ALIBinder.Codeunit.al)

Single AST pass resolving:

- Symbols (scoped, int-keyed via interned names)
- Types + conversions (`ConvOrd`)
- Register slots (per type class)

Core components:

- **Symbol Table** (struct-of-arrays + scope chain)
- **Type Rules** (operator matrix from native AL)
- **Builtin Registry** (complete surface; partial impl allowed)
- **Metadata oracles** (Record/Field/Enum resolution at bind-time)

Key properties:

- **No runtime type checks** (fully annotated at bind)
- **Two-pass procedure binding** (forward calls)
- **Strict var-param + lvalue validation**
- **Register allocation**: params → locals → reusable temp pool

AST is immutable; binder writes **parallel annotation columns**:
`TypeOrd`, `SymbolId`, `ConvOrd`, `SlotIndex`.

---

### 4.6 Method Dispatch Model

Uses **negative SymbolId markers**:

```
FieldRef/KeyRef (-16000) → RecordRef (-15000) → Media (-14000) → BigText/SecretText (-13000) → Xml → Blob → Json (-10000) → Http → Dialog → RecordId → Dict → List → TextBuilder → Builtin → Stream → Record (-1000)
```

- `SymbolId > 0` → user symbol
- `SymbolId < 0` → dispatch family + method ID
- Dispatch resolved in lowerer/interpreter via mark ranges

#### Ladder ordering

Every dispatch cascade is a **descending `Sym <= X` ladder**, so a new family must take the MOST negative mark or it is never matched.

**The ladder has five rungs to keep in step** (statement dispatch ×2, expression dispatch ×2, property-set assignment ×1); miss one and the RecordRef arm silently swallows a FieldRef call.

#### RecordRef

`RecordRef` (-15000) is deliberately a *thin* family: only the RecordRef-only surface carries this mark — `Open`/`Close`/`Number`/`Name`/`Caption`/`GetTable`/`SetTable`/`Duplicate`/`FieldExist`/`System*No`/`Field`/`FieldIndex`/`KeyIndex` (ids 1-17), plus the **field-NUMBER** surface (ids 18-39: `SetRange`/`SetFilter`/`Validate`/`ModifyAll`/`SetLoadFields`/…).

Every other RecordRef method is re-marked `Record` (-1000) by the binder and lowered to the existing `REC_*` opcode — a RecordRef receiver holds the same `"ALI Rec Runtime"` handle a Record receiver holds.

The field-number block has its own ids rather than reusing the `REC_*` twins because the twins take a **bind-time-constant** field number burned into the instruction (the Record fast path), while `REF_METHOD`'s operand pool is the live-register kind, so a run-time field number is just one more live operand. Its packing repurposes the freed `OutCls` digit as a flags field, deriving the result class from the method id (the `FLD_METHOD` trick), needed because `GetRangeMin`/`GetRangeMax` return a Variant (class 11) on this receiver.

#### FieldRef / KeyRef

`FieldRef`/`KeyRef` (-16000) share **one** mark and **one** opcode (`FLD_METHOD`), separated by method-id range (FieldRef 1-31, KeyRef 40-43) — a KeyRef is four methods, and a third family would have cost more ladder rungs than it saved. Their VALUE is a packed pair `slot*2048 + recordHandle` in a plain Int register, so `:=`, parameters and returns come free from the Int machinery, with no bank and no lifecycle.

#### Receiver predicates and chained receivers

**Receiver predicates are structural.** Every `Is*Receiver` in `TryDispatchMemberMethod` peeks the receiver *without binding it* — `NKind = NameExpr` plus a `Symbols.Lookup` — because on the parenthesized path the receiver has not been bound yet and binding it twice is the hazard the convention exists to avoid. The cost: a **chained** receiver (`RRef.Field(3).Value` — a member call on another call's RESULT) matches none of them. Two mechanisms coexist:

- families that peek through `ExprTypePeek` (Xml, Json, Http, Text, Variant, RecordId) speculatively bind a non-name receiver against a throwaway diag bag and so handle chains;
- families that are strictly NameExpr-only (List, Dictionary, Stream, TextBuilder, Dialog, BigText, SecretText) do **not** — `Dict.Keys().Count()` is unsupported for them.

`RecordRef`/`FieldRef`/`KeyRef` keep their structural predicates for the variable case and add **one** extra ladder arm (`RefKindOfChainedReceiver`) placed immediately *above* the Xml rung: high enough to claim every ref-typed expression, low enough that the Media and Blob/BigText/SecretText arms above it — which match an *unbound* `Rec.<field>` member access structurally — are never pre-bound behind their backs. Every arm from Xml down already peeks, so that placement adds **zero** speculative binds. A `TypeOrd` fast path in the peek keeps an n-link chain linear instead of 2ⁿ binds.

#### Native codeunit catalogue

`MyCU.Method()` on Type Helper / Base64 Convert / Math / Encoding / Environment Information / Language / Cryptography Management / Data Compression / Temp Blob / Regex is not a family of its own: it binds (`BindNativeCall`, overload chosen on static argument types) to a builtin row of Domain `Native` and rides the Builtin mark / `CALL_BUILTIN_LIVE`, executed by [`ALI Native Runtime`](Runtime/ALINativeRuntime.Codeunit.al) on the real codeunit.

- Stateless codeunits stay `CodeunitRef` (no register, not an operand).
- Data Compression, Temp Blob and Regex are TypeKind `NativeCodeunit`, an Int handle into the runtime's instance bank, passed as operand 1 like any method receiver.
- A record argument of a native row (Regex Matches/Groups/Captures/Options, Language's Windows Language — all temporary) is bridged without copying: the native Record var shares the script record's temp dataset (`RecordRef.SetTable(Rec, true)` over `"ALI Rec Runtime".ShareTempRef`) and the current row comes back through `AdoptTempRef`. A `List of [Text]` argument is copied in and replaced after the call.
- Rows are appended last in the registry so stored BuiltinIds never move.
- The static platform receivers `Page.Run` / `Report.Run` / `File.DownloadFromStream` / `File.UploadIntoStream` (and the bare legacy File names) are rows of the same catalogue under negative pseudo codeunit ids (`FileNativeId` -1, `PageNativeId` -2, `ReportNativeId` -3), routed by `TryDispatchMemberMethod` right after the `Codeunit.Run` arm (receiver annotated `CodeunitRef`, so not an operand); their record argument goes to the platform through `RecordAsVariant`, as for `Codeunit.Run`.

#### Events in harvested objects

No runtime or binder machinery: `"ALI App. Obj. Metadata".GetALObjectProceduresCode` rewrites each event publisher's empty body into plain AL — one `Codeunit` local + one by-name call per active, non-manual `"Event Subscription"` row, in record order — and keeps `[EventSubscriber]` procedures as plain procedures. Raising an event is then a sibling call and each subscriber a normal cross-object harvest; `sender` of a table event is the unit's `Rec`. Trigger events stay native (record runtime).

---

### 4.7 Paren-less Calls

AL allows `MyProc;` or `x := MyFunc`.

Handled by:

- Dual-shape arg detection (`InvocationExpr` vs implicit 0 args)
- Shared dispatch path
- Same lowering → identical bytecode

---

### 4.8 Optimizer (Optional)

Files: [`Semantic/ALIPassManager.Codeunit.al`](Semantic/ALIPassManager.Codeunit.al), [`Semantic/Optimizer/`](Semantic/Optimizer/)

AST-to-AST passes, each an implementation of the `ALI Opt Pass` interface selected through an enum:

- Constant folding (typed + pure builtins)
- Constant propagation
- Dead branch elimination

Controlled via `"ALI Engine".SetOptimize(true)` (off by default).

---

### 4.9 Lowerer + Module

Files: [`Runtime/ALILowerer.Codeunit.al`](Runtime/ALILowerer.Codeunit.al), [`Runtime/ALIModule.Codeunit.al`](Runtime/ALIModule.Codeunit.al)

Transforms AST → **register-based bytecode**.

Module layout:

- Instruction columns: `Op, A, B, C`
- Const pools (per type)
- Proc table (entry PC, registers, params, result)
- Operand pool (variadic ops)
- Debug map (PC → source line/column)

Design principle: **frontload complexity to compile phase**.

---

### 4.10 Interpreter

File: [`Runtime/ALIInterpreter.Codeunit.al`](Runtime/ALIInterpreter.Codeunit.al), dispatching to `Runtime/ALI*Runtime.Codeunit.al`

Executes:

- **Typed registers (no boxing where possible)**
- Fixed arrays (fast indexed access)
- No name/type resolution at runtime
- Statement budget (`ALI950` after 100M statements, `ALI Limits`) against runaway loops; `RunOptions.SetStatementBudget` currently not read

#### Transaction scope

A run is a conditional `Codeunit.Run` on the interpreter itself — the only AL construct giving the run its own rollback scope. The host's pending writes are **committed** just before it starts.

| Exec mode | Behavior |
|---|---|
| `Normal` | Script `COMMIT` is real. A runtime error rolls back to the run start (or last script `COMMIT`). |
| `Simulation` | Loop runs under `CommitBehavior::Ignore`; a clean run ends with a sentinel error that forces rollback and is reported as success. All DB writes are undone. |

`Message`, `Error` and `Sleep` are always intercepted; `Confirm`/`StrMenu`/`GuiAllowed` follow [`ALI Run Options`](Runtime/ALIRunOptions.Codeunit.al) (see [Run options](#run-options)).

#### `[TryFunction]` calls (`TRY_CALL`, opcode 474)

A try call whose outcome is consumed stages its arguments like `CALL`, then `TRY_CALL A=procId B=boolReg`.

The interpreter cannot catch an arbitrary arm's error inside the loop, so `ExecTryCall` pushes the callee frame with a **return PC of `InstrTotal`** and re-enters `RunLoopFlat` natively from a `[TryFunction]` (`TryRunFrame`) — legal because all run state (PC, frames, bases, registers, alloc stack, loop scratch vars) is codeunit-global. The callee's ordinary `RET` pops the frame and lands on `PC = InstrTotal`, which is exactly the loop's exit condition, so neither `RET` nor the per-instruction path pays anything.

- **Success:** `PC` back to the `TRY_CALL`, `B := true`.
- **Failure:** fatal errors (budget/stack/registers/limits/uncompiled proc/nesting cap) are re-raised with PC untouched so `Run()` still reports the failing line; any other error unwinds every frame above the call (`UnwindFramesTo`: handle reclaim + base restore), copies the message into the script's `GetLastErrorText`, and sets `B := false`.

Each try level costs AL stack, hence its own cap (64). A try call used as a statement is lowered as a plain `CALL`.

---

### 4.11 JSON Opcode Extension

Due to ID space limits:

- `JSON_METHOD` — method IDs < 100
- `JSON_METHOD2` — method IDs ≥ 100, stored rebased by -100

Operand packing:

```
A = receiver reg
B = operand pool index
C = OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount
```

Method IDs partitioned by receiver type:

- JsonObject / JsonArray / JsonToken / JsonValue ranges

---

### 4.12 Performance Model

Key principles:

- **Integer-based everything** (ids, slots, types)
- **No string comparisons after lexing**
- **No dynamic allocation in hot path**
- **Register VM > AST walking**
- **Compile-time resolution of metadata + types**
- **As close as possible to native operation**
- **Hot opcodes inlined in `RunLoopFlat`** — an AL procedure call costs far more than the work it usually wraps, so hot dispatch arms and their scratch state live directly in the loop / codeunit members instead of helper procedures (~x30 → ~x15 vs native). Readability traded for speed on purpose. See [Performance](#performance) for measured numbers.

---

### 4.13 Guarantees

- Near-native AL semantics on supported surface
- Deterministic diagnostics (non-short-circuiting)
- Serializable intermediate representations
- Fully testable pipeline stages (isolated stores)
