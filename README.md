# AL Interpreter for Business Central (ALI)

Write and run AL code **directly inside Business Central** web client. ALI respect precisely native AL code behavious.

Typical uses:
- **Ad-hoc scripts and data fixes** — run a one-off correction on live data.
- **Investigation** — query tables, test AL concept, inspect results without leaving web client.
- **AI-generated code** — let an AI assistant write and execute AL safely, with clear error feedback it can correct from.

> This app was designed and mostly developed with Anthropic Claude (Fable 5.1 and Opus 5). Even with extended test coverage, error may happen. Alway test it on sandbox before running it on production environement.

## Contents

1. [Live code editor](#1-live-code-editor)
2. [Build & On-Premise vs Cloud](#2-Build-OnPremise-vs-Cloud)
3. [Supported features](#3-supported-features)
4. [Calling ALI from AL](#4-calling-ali-from-al)
5. [Architecture](#5-architecture)

## 1. Live code editor

Search for page "AL Script Editor" :
<!-- SCREENSHOT 1: full editor page — code with syntax coloring on the left, Result pane with a successful run on the right. Best "hero" image, keep it wide. -->
![Screenshot full code editor page](https://github.com/MaximeCaty/AL-Interpreter/blob/main/Images/Screenshot-Sample.png?raw=true)

The **AL Script Editor** page brings a VS Code-like experience into the Business Central web client with collboration of JavaScript addin and AL metadata.
Type AL, press **F5**, read the result. 

### Autocompletion

Builtin methods, record fields and procedures, variable definition, are all suggested while typing in searchable dropdown list.

<!-- SCREENSHOT 2 (optional): completion popup open on `Customer.` showing fields, or hover tooltip on a procedure. -->
<img src="https://github.com/MaximeCaty/AL-Interpreter/blob/main/Images/Screenshot-AutoCompletion.png" alt="Screenshot-AutoCompletion" width="50%"/>

### Live syntax check

<!-- SCREENSHOT 3 a script with 2–3 errors underlined, Problems panel open below showing the messages (one with a "did you mean" hint). -->
![Screenshot syntax error](https://github.com/MaximeCaty/AL-Interpreter/blob/main/Images/Screenshot-Syntax-Error.png?raw=true)

Code is checked **as you type**. 
Errors are underlined in place and listed in the **Problems** panel. 
Real semantic checks against your database — unknown tables, fields or procedures, wrong argument types, invalid `var` arguments — not just keyword coloring.


### Multi-tab

Several scripts can be open at once in tabs. 
New tab are scratch buffer; once you give it a name (click on tab name to edit) it becomes a stored script and is auto-saved. Stored scripts reopen from the script list.

<!-- SCREENSHOT 4: tab strip with 2–3 open scripts, one being renamed inline. -->
<img src="https://github.com/MaximeCaty/AL-Interpreter/blob/main/Images/Screenshot-MultiTabs.png?raw=true" alt="Screenshot multi tab" width="50%"/>

### Compile & run options

<!-- SCREENSHOT 5: the Options page (Compiler Options + Execution Options groups). -->
<img src="https://github.com/MaximeCaty/AL-Interpreter/blob/main/Images/Screenshot-Compile-Options-dropdown.png?raw=true" alt="Screenshot-Compile-Options-dropdown" width="200"/>
<img src="https://github.com/MaximeCaty/AL-Interpreter/blob/main/Images/Screenshot-Compile-Options.png?raw=true" alt="Screenshot-Compile-Options" width="75%"/>

| Option | Default | Effect |
|---|---|---|
| **Simulation / Normal** (toolbar toggle) | Simulation | Simulation rolls back every database write at the end, even on success — safe on live data. Normal commits. |
| Verbose | Off | Errors quote the source line with a caret and a plain-language hint |
| Optimize | Off | Precompute constant expressions, drop dead branches |
| Allow HTTP | Off | Permit outbound `HttpClient` calls |
| Allow protected table write | Off | Permit writes to posted documents, ledger entries and registers |
| Apply record security filters | Off | Script only sees records the user is allowed to see |
| Show record operation counts | Off | List insert/modify/delete counts per table after the run |
| Message handler | Log | Collect `Message()` in the result, or also show it as a real dialog |
| Confirm / StrMenu handler | Default | Scripted answer (otherwise `false` / `0` + warning), raise an error, or show the real dialog |
| Dialog (GuiAllowed) | Show | Real `GuiAllowed`, or always `false` to simulate a headless session |

The compiled script is cached with the stored script: an unchanged script re-runs without compiling. **Force run** (Ctrl+F5) recompiles, which you need after changing an object the script calls.

### Preprocessor symbols

> On premise only. A cloud build cannot read published object AL source, so there is nothing for these symbols to apply to and the page is not shipped — see [Build flavors](#5-build-flavors-on-premise--cloud).

When a script calls a procedure of an existing published object, ALI reads that object's AL source from the database and compiles it on the fly. If that source contains conditional compilation directives (`#if CLEAN25 ... #endif`, `#if not CLEAN24 ...`), ALI must know which symbols were defined when the extension was built.

The **Preprocessor** toolbar button opens a page where you declare these symbols **per published extension**. `#define` / `#undef` inside a file are always honored on top of this set.

### AI friendly

Built to be driven by an AI small model with secure and comprhensive output

- **Safe by default** — Simulation mode : let an AI agent run code on real data without side effects. Tunable option to allow httprequest, additional record security filtering (eg user responsibility center) ect. The interpreter herit user permision anyway.
- **Errors built for self-correction** — all errors are reported at once, with source line, caret, hint and "did you mean". Common C#/JavaScript slips (`==`, `&&`, `"text"`, `;` before `else`, `String`/`int`) get their AL spelling in the hint.
- **Warnings for classic mistakes** — e.g. reading a FlowField without `CalcFields`.
- **Callable from AL** — public API ([section 3](#3-calling-ali-from-al)) lets you run the interpreter with your own extension, you can publish  endpoint calling AL-Interpreter to compile and run a script and read back messages, return value and errors as text or JSON.

### Performance

> ⚠️ **Slower than native AL — expect ~10× the run time** on typical business logic (loops, sub procedures, text and collection work). Use it for ad-hoc scripts, data fixes, investigations and AI-generated code, not as a replacement for compiled extensions.

Why: the interpreter itself is written in AL, each statement costs several real AL statements. Database work is not slowed down — reads/writes/filters/table triggers runned natively and respect user permission. The overhead sits on the surrounding logic, SQL-heavy scripts (a few large `FindSet` / `ModifyAll`) would come much closer to native speed.

The **Benchmark** action on the options page measures this on your own data using customer table : the same workload (record read, text, char arithmetic, decimal, date, list, dictionary, sub procedure calls) runs as native AL and through ALI, both returning a checksum that match.

Sample :

| Customers | Native AL | ALI | ALI compile | Ratio |
|---|---|---|---|---|
| 10 000 | 86 ms | 901 ms | 20 ms | ×10.5 |
| 100 000 | 768 ms | 8 833 ms | 17 ms | ×11.5 |

---

## 2. Build OnPremise vs Cloud

### What a cloud build cannot do

Everything the interpreter does on its own — lexing, parsing, binding, optimizing, lowering,
running, the whole supported feature surface of [chapter 3](#3-supported-features) — is identical
in both flavors. What differs is anything that has to read **the AL source of an already published
object**, which lives on table `Application Object Metadata`. That table's scope is `OnPrem`: no
cloud extension may reference it, and the platform offers no substitute on SaaS.

| Feature | On premise | Cloud |
|---|---|---|
| Calls into existing objects (`Cust.MyProc()`, `MyCU.MyProc()`) | yes | no — reported as ALI961, naming the reason |
| Member names / captions of a standalone **Enum object** | yes | no — the existing ALI987 gate; integer enum semantics still work |
| Enum and option **fields** of a table | yes | yes — read through `FieldRef`, not through source |
| Procedures of existing objects in the completion dropdown | yes | not offered (the compiler cannot resolve them either) |
| Preprocessor Symbols page | yes | not shipped |
| `GetLastErrorObject()` | yes | ALI982 at compile time |
| `EnvironmentInformation.GetEnvironmentSetting()` | yes | ALI982 at compile time |

`ALI982` cases are real AL methods whose own scope is `OnPrem`; they stay in the builtin
catalogue in both flavors (so every `BuiltinId` — which serialized bytecode carries raw — is
identical across builds) and are refused at bind time with the reason, rather than silently
missing.

### Build

One source tree, built two ways. The flavor is chosen entirely in `app.json` — `target` plus two
preprocessor symbols — and nothing else in the repository needs touching.

| Symbol | Defined when | Effect |
|---|---|---|
| `CLOUD` | building for a cloud (SaaS / per-tenant) installation | Excludes everything that depends on OnPrem-scoped platform surface |
| `TEST` | building a test run | Includes everything under [`Test/`](Test/) |

`app.json` as committed is the **on-premise development** build: `"target": "OnPrem"` with
`"preprocessorSymbols": ["TEST"]`, so F5 and the test runner work as before.

| Flavor | `target` | `preprocessorSymbols` | `dependencies` |
|---|---|---|---|
| On premise, development | `OnPrem` | `["TEST"]` | Library Assert |
| On premise, release | `OnPrem` | `[]` | *(empty)* |
| Cloud, development | `Cloud` | `["CLOUD", "TEST"]` | Library Assert |
| Cloud, release | `Cloud` | `["CLOUD"]` | *(empty)* |

`TEST` exists so a public release ships without the test codeunits and therefore without the
dependency on Microsoft's **Library Assert**, which is not installed by default. Drop `TEST` from
`preprocessorSymbols` *and* empty `dependencies` together — the symbol removes the code, the
manifest removes the requirement.

---

## 3. Supported features

The interpreter respect native AL compiler (alc.exe) and runtime behavior of Busienss central. It translate written code to bytecode that run native AL statement as much as possible.

- ✅ supported, behaves exactly like native AL
- 🔶 recognized — compiles, but report "not implemented yet" error
- ❌ not supported

Reference: [AL data types and methods](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/methods-auto/library).

### 3.1 Data types

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
| HttpClient & Http* family | ✅ | requires the *Allow HTTP* option (default off) |
| JsonObject / JsonArray / JsonToken / JsonValue | ✅ | |
| Xml* (all 16 types) | ✅ | |
| Dialog | ✅ | |
| Codeunit variables (`MyCU.Proc()`), `Codeunit.Run` | ✅ | procedures of your own codeunits are compiled on the fly; `Codeunit.Run` executes natively |
| Table & tableextension procedures (`Rec.MyProc()`) | ✅ | object global variables included |
| Event publishers / subscribers | ✅ | raising an event runs every active subscriber; the `IsHandled` pattern works |
| Native codeunits (Type Helper, Base64 Convert, Math, Encoding, Environment Information, Language, Cryptography Management, Data Compression, Temp Blob, Regex) | ✅ | called natively (§2.10) |
| Media / MediaSet fields | 🔶 | read ✅, import / insert / remove ❌ |
| ErrorInfo, File / FileUpload | 🔶 | |
| DotNet | ❌ | procedures using DotNet are blocked; the rest of the object still works |
| Page, Report, Query, XmlPort, Notification, TestPage variables | ❌ | static `Page.Run` / `Report.Run` ✅ |
| IsolatedStorage, TaskScheduler, Session, NavApp, ModuleInfo, DataTransfer, FilterPageBuilder, NumberSequence, … | ❌ | |

### 3.2 Statements & language

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
- Preprocessor directives `#if` / `#elif` / `#else` / `#endif`, `#define` / `#undef`
- `with` rejected (as with `NoImplicitWith`)

### 3.3 Record methods

All ✅ unless noted:

`Init`, `Reset`, `Insert`, `Modify`, `Delete`, `DeleteAll`, `ModifyAll`, `Rename`, `Truncate`, `Get` (incl. RecordId), `GetBySystemId`, `Find`, `FindFirst`, `FindLast`, `FindSet`, `Next`, `Count`, `CountApprox`, `IsEmpty`, `SetRange`, `SetFilter`, `GetFilter(s)`, `CopyFilter(s)`, `SetRecFilter`, `GetRangeMin/Max`, `GetView/SetView`, `GetPosition/SetPosition`, `HasFilter`, `FilterGroup`, `SetCurrentKey`, `CurrentKey`, `Ascending`, `KeyCount`, `CalcFields`, `CalcSums`, `SetAutoCalcFields`, `SetLoadFields`, `AddLoadFields`, `LoadFields`, `AreFieldsLoaded`, `Copy`, `TransferFields`, `Validate`, `TestField`, `FieldError`, `Mark`, `ClearMarks`, `MarkedOnly`, `LockTable`, `ReadIsolation`, `ReadConsistency`, `RecordLevelLocking`, `SecurityFiltering`, `SetPermissionFilter`, `ReadPermission/WritePermission`, `ChangeCompany`, `CurrentCompany`, `IsTemporary`, `RecordId`, `TableName`, `TableCaption`, `FieldName`, `FieldCaption`, `FieldCount`, `FieldExist`, `AddLink`, `DeleteLink(s)`, `CopyLinks`, `HasLinks`.

❌ `FieldActive`, `FieldNo`, `Relation`, `Consistent`, `SetBaseLoadFields`.

**Record security** (option): every table read is restricted to the records the user is allowed to see; the script cannot remove these filters.

### 3.4 RecordRef / FieldRef / KeyRef

- **RecordRef** ✅ — `Open` (by id or by table name), `Close`, `Number`, `Name`, `Caption`, `GetTable`, `SetTable`, `Duplicate`, `Field` (by number or name), `FieldIndex`, `KeyIndex`, `FieldExist`, `System*No`, plus every Record method above and the field-number forms (`SetRange`, `SetFilter`, `Validate`, `CalcFields`, `SetLoadFields`, …).
- **FieldRef** ✅ — `Value` (get/set), `Validate`, `SetRange`, `SetFilter`, `GetFilter`, `GetRangeMin/Max`, `CalcField`, `CalcSum`, `TestField`, `FieldError`, `Name`, `Number`, `Caption`, `Length`, `Active`, `Relation`, `Class`, `Type`, `OptionCaption`, `OptionMembers`, enum helpers, `IsOptimizedForTextSearch`, `Record`. `Value` on Blob / Media fields ❌.
- **KeyRef** ✅ — `Active`, `FieldCount`, `FieldIndex`, `Record`.
- Chaining works: `RRef.Field(3).Value := x`, `RRef.KeyIndex(1).FieldIndex(1).Name`.

### 3.5 Text

✅ `CopyStr`, `StrLen`, `MaxStrLen`, `StrPos`, `StrSubstNo`, `Format`, `LowerCase`, `UpperCase`, `DelChr`, `ConvertStr`, `PadStr`, `IncStr`, `SelectStr`, `Evaluate`, `DelStr`, `InsStr`, `StrCheckSum`, and the instance methods `Contains`, `StartsWith`, `EndsWith`, `IndexOf`, `LastIndexOf`, `IndexOfAny`, `Replace`, `Split`, `Substring`, `ToLower`, `ToUpper`, `Trim`, `TrimStart`, `TrimEnd`, `PadLeft`, `PadRight`, `Remove`, `s[i]`.

### 3.6 Collections & builders

- **List** ✅ `Add`, `AddRange`, `Get`, `Set`, `Count`, `Contains`, `IndexOf`, `Insert`, `Remove`, `RemoveAt`, `RemoveRange`, `GetRange`, `Reverse` — ❌ `ToArray`
- **Dictionary** ✅ `Add`, `Set`, `Get`, `ContainsKey`, `Remove`, `Count`, `Keys`, `Values`
- **TextBuilder** ✅ full surface
- **BigText** ✅ `AddText`, `GetSubText`, `Length`, `TextPos`, `Read`, `Write`
- **SecretText** ✅ `IsEmpty`, `Unwrap`, `SecretStrSubstNo`
- **Media / MediaSet** ✅ `MediaId`, `HasValue`, `ExportStream`, `Count`, `Item` — ❌ `ImportStream`, `Insert`, `Remove`

### 3.7 Streams

✅ `WriteText`, `WriteLine`, `ReadText`, `Write`, `Read` (typed binary I/O), `EOS`, `Length`, `Position`, `ResetPosition`, `CopyStream`.

### 3.8 HTTP, JSON, XML

- **Http** ✅ `HttpClient` (`Get`, `Post`, `Put`, `Delete`, `Send`, `SetBaseAddress`, `Timeout`, `DefaultRequestHeaders`), `HttpRequestMessage`, `HttpResponseMessage`, `HttpContent`, `HttpHeaders`. Certificates / auth helpers ❌.
- **Json** ✅ full `JsonObject` / `JsonArray` / `JsonToken` / `JsonValue` surface, typed getters included (`GetText`, `GetInteger`, `GetObject`, …), `SelectToken`, `Clone`, `Keys`. JsonArray stays 0-based like native.
- **Xml** ✅ full documented surface of all 16 Xml types: create / read / write (text and streams), XPath `SelectNodes` / `SelectSingleNode` with namespaces, attributes, navigation.

### 3.9 System functions

| ✅ | 🔶 | ❌ |
|---|---|---|
| `Abs`, `Round`, `Power`, `Random`, `Randomize`, `Today`, `Time`, `CurrentDateTime`, `WorkDate`, `CalcDate`, `Date2DMY`, `Date2DWY`, `DMY2Date`, `DWY2Date`, `CreateDateTime`, `DT2Date`, `DT2Time`, `ClosingDate`, `NormalDate`, `RoundDateTime`, `Evaluate`, `Format`, `Clear`, `ClearAll`, `GetLastErrorText`, `ClearLastError`, `GetLastErrorCallStack`, `ArrayLen`, `CopyArray`, `CompressArray`, `Message`, `Error`, `Confirm`, `StrMenu`, `Sleep`, `GuiAllowed`, `CompanyName`, `UserId`, `UserSecurityId`, `SessionId`, `CreateGuid`, `IsNullGuid`, `GetUrl`, `GlobalLanguage`, `WindowsLanguage`, `SelectLatestVersion`, `CurrentClientType`, `CurrentExecutionMode`, `CopyStream`, `Variant2Date`, `Variant2Time`, `DaTi2Variant`, `Codeunit.Run`, `Page.Run`, `Report.Run`, `DownloadFromStream`, `UploadIntoStream`, `Database::` / `Codeunit::` / `Enum::` ids | `CurrReport`, `CurrPage`, `CurrFieldNo`, `Hyperlink`, `LogMessage`, `FeatureTelemetry`, `Download`, `Upload`, `FileExists`, `ErrorInfo` | Encryption functions, error-collection functions, `IsNull`, `GetDotNetType`, `ApplicationPath`, `TemporaryPath`, `CaptionClassTranslate`, `GetDocumentUrl` |

`Message` / `Error` are captured in the run result; `Confirm` / `StrMenu` answers can be scripted.

### 3.10 Native codeunits

These system codeunits are called on the real object, so their DotNet-based implementation works:

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

### 3.11 Diagnostics

- All errors reported at once, with line and column
- Verbose mode: source line, caret and hint under each error; runtime errors explain 1-based vs 0-based indexes, missing dictionary keys, …
- "Did you mean" for unknown methods, fields, tables and codeunits
- No error cascade after an unknown call
- Warning for a FlowField read without `CalcFields`
- Error codes can be hidden for cleaner output

---

## 4. Calling ALI from AL

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

### Public objects

| Object | ID | Role |
|---|---|---|
| [`ALI Engine`](Runtime/ALIEngine.Codeunit.al) | codeunit 51029 | Compile, run, save/load compiled script, compile options |
| [`ALI Run Options`](Runtime/ALIRunOptions.Codeunit.al) | codeunit 51035 | Run options: exec mode, UI handling, security gates |
| [`ALI Diag Bag`](Foundation/ALIDiagBag.Codeunit.al) | codeunit 51008 | Compile diagnostics (errors, warnings, infos) |
| [`ALI Exec Result`](Runtime/ALIExecResult.Codeunit.al) | codeunit 51030 | Run outcome: success, error + position, return value, messages |
| `ALI Exec Mode`, `ALI Dialog Mode`, `ALI Interaction Mode`, `ALI Message Mode` | enums 51004, 51015–51017 | Option values (see [Run options](#run-options)) |

`ALI Engine` and `ALI Run Options` are **`SingleInstance`**: settings persist for the whole session and are shared with every other caller (Script Editor, AI tool…). Set everything you depend on before each run.

### Quick start

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

### Script shape and entry point

| Shape | Example |
|---|---|
| Statement block | `Message('Hello');` — wrapped in an implicit `OnRun` |
| Procedure set | globals (`var ...`) + procedures + optional `trigger OnRun()` |
| Codeunit shell | `codeunit 50000 X { ... }` |

Entry point:

- **Default** (`Engine.SetRequireOnRun(false)`): the procedure named `OnRun`, else the **first declared** procedure. Declare the entry procedure first — a helper declared first would run with zero parameters.
- **Strict** (`Engine.SetRequireOnRun(true)`, used by the Script Editor): only `trigger OnRun()` qualifies; missing = error `ALI1000`.

The entry procedure/trigger may return a value (`trigger OnRun(): Integer`), available formatted in `Result.ResultText()`.

### Compile, then run

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

### Reading diagnostics

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

### Reading the result

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

### Run options

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

The stored text includes the script **and** every AL object it calls. Key it on a hash of source, ALI app version, preprocessor symbols and compile options, and offer a forced recompile for when called objects change.

### Syntax check only

`Engine.CheckDiagnostics(Source, Diags)`: fast check without producing a runnable script (`RunCompiled` fails afterwards). Called objects are checked by signature only. Use it for as-you-type checks; `Compile` before running.

### Pitfalls

- **Single instance.** Another caller may have left `SetRequireOnRun(true)`, verbose or Simulation on. Call `RunOptions.Reset()` and every `Engine.Set*` you rely on before each run.
- **Caller commit.** Running a script commits the caller's pending writes first.
- **Statement budget.** Runs abort after 100M executed statements.
- **Entry point.** In default mode the first declared procedure runs; declare the entry procedure first.
- **Background sessions.** `Show` modes need a GUI session; in job queue / web service contexts they fall back to headless behavior.

The Script Editor page ([`ALCodeEditor/ALIScriptEditor.Page.al`](ALCodeEditor/ALIScriptEditor.Page.al)) is a complete reference caller: options from the stored script record, strict `OnRun`, stored compiled script, `Warmup` on open.

---

## 5. Architecture

ALI is a classic compiler pipeline followed by a register-based bytecode interpreter, all in AL. This section explains the general principles; the source is the detailed reference.

### Folder layout

| Folder | Content |
|---|---|
| [`Foundation/`](Foundation/) | Shared enums (`TokenKind`, `NodeKind`, `Opcode`, `TypeKind`, run modes…), token table, diagnostics bag, capacity constants (`ALI Limits`) |
| [`Frontend/`](Frontend/) | Lexer, parser, flat AST store, preprocessor symbols |
| [`Semantic/`](Semantic/) | Binder, symbol table, type rules, builtin and object registries, record & option metadata, optimizer passes |
| [`Runtime/`](Runtime/) | Engine facade, run options, exec result, lowerer, module, interpreter and per-family runtimes (Record, Json, Xml, Http, List, Dictionary, Stream, native codeunits…) |
| [`ALCodeEditor/`](ALCodeEditor/) | Script Editor page + control add-in (live diagnostics, API catalog, options page, preprocessor symbols page) |
| [`StoredALScript/`](StoredALScript/) | `ALI Stored Script` table (source + stored bytecode) and list page |
| [`Test/`](Test/) | Test codeunits per pipeline stage and test objects (tables, pages, events) |

### 5.1 Compilation pipeline

```
Source
 → Lexer        → Token table + diagnostics
 → Parser       → Flat AST + diagnostics
 → Binder       → Symbols, types, register slots + diagnostics
 → Optimizer    → Rewritten AST (optional)
 → Lowerer      → Module (typed register bytecode)
 → Interpreter  → Exec result
```

- `Compile` runs the full pipeline and keeps the Module for `RunCompiled`. `CheckDiagnostics` stops after the binder. `SaveCompiled` / `LoadCompiled` serialize the Module as JSON.
- Stages communicate through flat data stores (codeunits passed by `var`). Diagnostics are collected, never thrown at the first error.
- Execution runs **lowered bytecode, not the AST**: compile heavy, run fast.
- Calls to real AL objects (codeunits, tables, events) are resolved by the [`ALI Object Registry`](Semantic/ALIObjectRegistry.Codeunit.al), which reads the object's source from the database and compiles it together with the script.

### 5.2 Core representation: struct-of-arrays

AL has no heap objects or pointers, so every structure — tokens, AST nodes, symbols, instructions — is a set of **parallel arrays indexed by integer handles**. At compile time these are `List of [T]`; at run time they are fixed arrays, sealed when the Module is loaded. Enums such as `TokenKind`, `NodeKind` and `Opcode` are dense, append-only ordinals, which keeps serialized modules stable across versions.

### 5.3 Lexer

[`Frontend/ALILexer.Codeunit.al`](Frontend/ALILexer.Codeunit.al) — single-pass scanner producing a token table (`Kind`, `Pos`, `Len`, `Line`, `Col`, `ValueIdx`) with separate literal pools. Identifiers are interned case-insensitively to integer ids, so nothing after the lexer compares strings. Preprocessor directives are resolved here, using the symbols declared for the object's extension.

### 5.4 Parser

[`Frontend/ALIParser.Codeunit.al`](Frontend/ALIParser.Codeunit.al) and companions — recursive descent producing a flat AST (each node: `Kind`, `Token`, `FirstChild`, `ChildCount`, `Extra`). Expressions use Pratt parsing with native AL precedence, including the if/else semicolon rule. Error recovery (token insertion + resync) lets the parser report several errors per pass. A nesting-depth guard prevents AL stack overflow.

### 5.5 Binder

[`Semantic/ALIBinder.Codeunit.al`](Semantic/ALIBinder.Codeunit.al) — single pass over the AST resolving symbols, types, conversions and register slots. Type rules mirror the native operator matrix; a builtin registry describes the whole AL surface (with partial implementations reporting "not implemented"); metadata oracles resolve tables, fields and enums at bind time. The AST stays immutable: the binder writes parallel annotation columns (`TypeOrd`, `SymbolId`, `ConvOrd`, `SlotIndex`). After binding, **no type or name resolution happens at run time**.

Methods on built-in types (Record, RecordRef, Json, Xml, Http, List, …) are dispatched by family: each family owns a range of negative symbol ids, and the lowerer maps them to family-specific opcodes. Calls on native system codeunits (Type Helper, Regex, …) bind to builtin rows and are executed on the real codeunit.

Events need no runtime machinery: when an object is read from the database, each event publisher's empty body is rewritten into direct calls to its active subscribers, so raising an event is an ordinary procedure call.

### 5.6 Optimizer (optional)

[`Semantic/Optimizer/`](Semantic/Optimizer/) — AST-to-AST passes selected through an enum + interface: constant folding, constant propagation, dead-branch elimination. Enabled with `SetOptimize(true)`.

### 5.7 Lowerer and module

[`Runtime/ALILowerer.Codeunit.al`](Runtime/ALILowerer.Codeunit.al), [`Runtime/ALIModule.Codeunit.al`](Runtime/ALIModule.Codeunit.al) — transform the AST into register-based bytecode. The Module holds instruction columns (`Op, A, B, C`), typed constant pools, a procedure table, an operand pool for variadic operations and a debug map (PC → source line/column) used for runtime error positions.

### 5.8 Interpreter

[`Runtime/ALIInterpreter.Codeunit.al`](Runtime/ALIInterpreter.Codeunit.al), delegating to `Runtime/ALI*Runtime.Codeunit.al` per family.

- Typed registers (Int, Decimal, Text, Boolean, handles…), fixed arrays, no boxing where avoidable.
- A statement budget (100M) stops runaway loops with error `ALI950`.
- **Transaction scope**: a run is a conditional `Codeunit.Run` on the interpreter itself, the only AL construct that gives it its own rollback scope. In Simulation mode the loop runs with commits ignored and a clean run ends with a sentinel error that forces the rollback, then reports success.
- `[TryFunction]` calls re-enter the execution loop natively from a try function, so a failing callee unwinds only its own frames and the script's `GetLastErrorText` is set.

### 5.9 Performance model

- Everything is an integer after lexing: ids, slots, types, opcodes. No string comparison in the hot path.
- No dynamic allocation while running; all state is pre-sized when the Module is loaded.
- Register VM rather than AST walking; all metadata and type resolution done at compile time.
- **Hot opcodes are inlined in the execution loop.** An AL procedure call costs far more than the work it usually wraps, so the most frequent operations live directly in the loop instead of helper procedures. This brought the ratio from about ×30 to about ×11 vs native, at the price of a large and deliberately ugly main loop.
- Room is left: inlining everything and merging all runtime codeunits into one would come closer still to native speed. Not done on purpose — it would be tens of thousands of lines in a single unmaintainable codeunit.

### 5.10 Guarantees

- Near-native AL semantics on the supported surface
- Deterministic diagnostics: every error reported at once, never just the first
- Serializable intermediate representations (stored compiled scripts)
- Each pipeline stage testable in isolation (see [`Test/`](Test/))
