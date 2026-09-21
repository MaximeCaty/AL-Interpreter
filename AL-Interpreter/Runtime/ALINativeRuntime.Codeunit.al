// ALI Native Runtime — executes the native codeunit catalogue ("ALI Builtin Registry".PopulateNative).
//
// ALI runs INSIDE Business Central, so a catalogued call such as `TypeHelper.UrlEncode(s)` is not
// emulated: it is the very same call, made here on a real instance of the real codeunit. That is
// what makes DotNet-backed procedures (which the harvester can never compile) available at all.
//
// Boundary = the "ALI Builtin *" contract: array[16] of Variant + ArgCount, dispatched on the
// row's per-overload key UPPER(Tag.Method(Spec)). Two additions:
//   * Args is `var`: a `var` parameter of the native procedure is written back into Args[i], and
//     the interpreter copies it into the argument's register (the row's VarMask says which).
//   * Stream arguments arrive as stream HANDLES and are resolved through "ALI Stream Runtime";
//     a List argument is a list handle filled in place through "ALI List Runtime".
//
// Stateless codeunits (Type Helper, Base64 Convert, Math, Encoding, Environment Information,
// Language, Cryptography Management) are one shared global each.
// Data Compression, Temp Blob and Regex are STATEFUL (the zip archive / the blob / the pattern
// lives inside the instance), so each ALI variable of those types owns a slot of the instance
// bank — handle = slot, allocated by NCU_NEW at proc entry, freed on frame pop, same free-list
// scheme as "ALI Stream Runtime". One handle space for all three: slot H has a DataComp[H], a
// TempBlobs[H] AND a Regexes[H], and the binder only ever sends a handle to the rows of its own
// codeunit.
//   * Record arguments (Regex Matches/Groups/Captures/Options, Language's Windows Language) are
//     temporary: the native Record var SHARES the script record's dataset (ShareRec), and the
//     current row comes back after the call (AdoptRec).
//   * The static receivers `Page.Run` / `Report.Run` / `File.*Stream` are rows of this same
//     dispatch under pseudo codeunit ids — platform methods, no instance at all.
// SingleInstance so the bank survives the dispatch loop; Reset() by the interpreter per run.
codeunit 51124 "ALI Native Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        Base64: Codeunit "Base64 Convert";
        CryptoMgt: Codeunit "Cryptography Management";
        EncodingCU: Codeunit Encoding;
        EnvInfo: Codeunit "Environment Information";
        LanguageCU: Codeunit Language;
        ListRt: Codeunit "ALI List Runtime";
        MathCU: Codeunit Math;
        RecRt: Codeunit "ALI Rec Runtime";
        StrmRt: Codeunit "ALI Stream Runtime";
        TypeHelper: Codeunit "Type Helper";
        DataComp: array[16] of Codeunit "Data Compression";
        Regexes: array[16] of Codeunit Regex;
        TempBlobs: array[16] of Codeunit "Temp Blob";
        InstCount: Integer;
        InstFree: List of [Integer];

    procedure Reset()
    begin
        Clear(DataComp);
        Clear(Regexes);
        Clear(TempBlobs);
        InstCount := 0;
        Clear(InstFree);
    end;

    // ===== Stateful instance bank (TypeKind NativeCodeunit) =====

    procedure NewInstance(CodeunitId: Integer): Integer
    var
        H: Integer;
    begin
        if (CodeunitId <> Codeunit::"Data Compression") and (CodeunitId <> Codeunit::"Temp Blob") and (CodeunitId <> Codeunit::Regex) then
            Error('ALI980: codeunit %1 has no native instance bank', CodeunitId);
        if InstFree.Count() > 0 then begin
            H := InstFree.Get(InstFree.Count());
            InstFree.RemoveAt(InstFree.Count());
        end else begin
            InstCount += 1;
            if InstCount > InstanceCapacity() then
                Error('ALI963: too many concurrently live Data Compression / Temp Blob / Regex variables (max %1)', InstanceCapacity());
            H := InstCount;
        end;
        ClearSlot(H);
        exit(H);
    end;

    procedure FreeInstance(H: Integer)
    begin
        if (H < 1) or (H > InstCount) then
            exit;
        ClearSlot(H);
        InstFree.Add(H);
    end;

    // Clear(DC) / Clear(TempBlob): a fresh platform instance behind the same handle. Streams
    // already created from a cleared Temp Blob keep the old content, as in native AL.
    procedure ResetInstance(H: Integer)
    begin
        if (H < 1) or (H > InstCount) then
            exit;
        ClearSlot(H);
    end;

    local procedure ClearSlot(H: Integer)
    begin
        Clear(DataComp[H]);
        Clear(Regexes[H]);
        Clear(TempBlobs[H]);
    end;

    local procedure InstanceCapacity(): Integer
    begin
        exit(16);
    end;

    local procedure Inst(V: Variant): Integer
    var
        H: Integer;
    begin
        H := V;
        if (H < 1) or (H > InstCount) then
            Error('ALI964: native codeunit handle %1 out of range', H);
        exit(H);
    end;

    // ===== Dispatch =====

    procedure Invoke(DispatchKey: Text; var Args: array[16] of Variant; ArgCount: Integer; var ResultV: Variant)
    var
        TempCaptures: Record Captures;
        TempGroups: Record Groups;
        TempMatches: Record Matches;
        TempRegexOptions: Record "Regex Options";
        TempWinLanguage: Record "Windows Language" temporary;
        Dur: Duration;
        InS: InStream;
        SigInS: InStream;
        OutS: OutStream;
        H: Integer;
        Len: Integer;
        Names: List of [Text];
        SecKey: SecretText;
        EntryName: Text;
        T: Text;
        V: Variant;
    begin
        case DispatchKey of
            // --- codeunit 10 "Type Helper" ---
            'TH.URLENCODE(&TXT)':
                begin
                    T := Args[1];
                    ResultV := TypeHelper.UrlEncode(T);
                    Args[1] := T;
                end;
            'TH.URLDECODE(&TXT)':
                begin
                    T := Args[1];
                    ResultV := TypeHelper.UrlDecode(T);
                    Args[1] := T;
                end;
            'TH.HTMLENCODE(&TXT)':
                begin
                    T := Args[1];
                    ResultV := TypeHelper.HtmlEncode(T);
                    Args[1] := T;
                end;
            'TH.HTMLDECODE(&TXT)':
                begin
                    T := Args[1];
                    ResultV := TypeHelper.HtmlDecode(T);
                    Args[1] := T;
                end;
            'TH.URIESCAPEDATASTRING(TXT)':
                ResultV := TypeHelper.UriEscapeDataString(TxtOf(Args[1]));
            'TH.JAVASCRIPTSTRINGENCODE(TXT)':
                ResultV := TypeHelper.JavaScriptStringEncode(TxtOf(Args[1]));
            'TH.JAVASCRIPTSTRINGENCODE(TXT,BOOL)':
                ResultV := TypeHelper.JavaScriptStringEncode(TxtOf(Args[1]), BoolOf(Args[2]));
            'TH.CRLFSEPARATOR()':
                ResultV := TypeHelper.CRLFSeparator();
            'TH.LFSEPARATOR()':
                ResultV := TypeHelper.LFSeparator();
            'TH.NEWLINE()':
                ResultV := TypeHelper.NewLine();
            'TH.READASTEXTWITHSEPARATOR(INS,TXT)':
                begin
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    ResultV := TypeHelper.ReadAsTextWithSeparator(InS, TxtOf(Args[2]));
                end;
            'TH.FORMATDATE(DATE,INT)':
                ResultV := TypeHelper.FormatDate(DateOf(Args[1]), IntOf(Args[2]));
            'TH.FORMATDATE(DATE,TXT,TXT)':
                ResultV := TypeHelper.FormatDate(DateOf(Args[1]), TxtOf(Args[2]), TxtOf(Args[3]));
            'TH.FORMATDATEWITHCURRENTCULTURE(DATE)':
                ResultV := TypeHelper.FormatDateWithCurrentCulture(DateOf(Args[1]));
            'TH.FORMATDATETIME(DT,TXT,TXT)':
                ResultV := TypeHelper.FormatDateTime(DTOf(Args[1]), TxtOf(Args[2]), TxtOf(Args[3]));
            'TH.FORMATUTCDATETIME(DT,TXT,TXT)':
                ResultV := TypeHelper.FormatUtcDateTime(DTOf(Args[1]), TxtOf(Args[2]), TxtOf(Args[3]));
            'TH.FORMATDECIMAL(DEC,TXT,TXT)':
                ResultV := TypeHelper.FormatDecimal(DecOf(Args[1]), TxtOf(Args[2]), TxtOf(Args[3]));
            'TH.EVALUATE(&VAR,TXT,TXT,TXT)':
                begin
                    V := Args[1];
                    ResultV := TypeHelper.Evaluate(V, TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]));
                    Args[1] := V;
                end;
            'TH.GETCURRUTCDATETIME()':
                ResultV := TypeHelper.GetCurrUTCDateTime();
            'TH.GETCURRUTCDATETIMEISO8601()':
                ResultV := TypeHelper.GetCurrUTCDateTimeISO8601();
            'TH.EVALUATEUTCDATETIME(TXT)':
                ResultV := TypeHelper.EvaluateUTCDateTime(TxtOf(Args[1]));
            'TH.EVALUATEUNIXTIMESTAMP(BIGINT)':
                ResultV := TypeHelper.EvaluateUnixTimestamp(BigIntOf(Args[1]));
            'TH.GETCURRENTDATETIMEINUSERTIMEZONE()':
                ResultV := TypeHelper.GetCurrentDateTimeInUserTimeZone();
            'TH.CONVERTDATETIMEFROMUTCTOTIMEZONE(DT,TXT)':
                ResultV := TypeHelper.ConvertDateTimeFromUTCToTimeZone(DTOf(Args[1]), TxtOf(Args[2]));
            'TH.GETUSERTIMEZONEOFFSET(&DUR)':
                begin
                    Dur := Args[1];
                    ResultV := TypeHelper.GetUserTimezoneOffset(Dur);
                    Args[1] := Dur;
                end;
            'TH.ISNUMERIC(TXT)':
                ResultV := TypeHelper.IsNumeric(TxtOf(Args[1]));
            'TH.TEXTDISTANCE(TXT,TXT)':
                ResultV := TypeHelper.TextDistance(TxtOf(Args[1]), TxtOf(Args[2]));
            'TH.INTTOHEX(INT)':
                ResultV := TypeHelper.IntToHex(IntOf(Args[1]));
            'TH.BITWISEAND(INT,INT)':
                ResultV := TypeHelper.BitwiseAnd(IntOf(Args[1]), IntOf(Args[2]));
            'TH.BITWISEOR(INT,INT)':
                ResultV := TypeHelper.BitwiseOr(IntOf(Args[1]), IntOf(Args[2]));
            'TH.BITWISEXOR(INT,INT)':
                ResultV := TypeHelper.BitwiseXor(IntOf(Args[1]), IntOf(Args[2]));
            'TH.MAXIMUM(DEC,DEC)':
                ResultV := TypeHelper.Maximum(DecOf(Args[1]), DecOf(Args[2]));
            'TH.MINIMUM(DEC,DEC)':
                ResultV := TypeHelper.Minimum(DecOf(Args[1]), DecOf(Args[2]));

            // --- codeunit 4110 "Base64 Convert" ---
            'B64.TOBASE64(TXT)':
                ResultV := Base64.ToBase64(TxtOf(Args[1]));
            'B64.TOBASE64(TXT,BOOL)':
                ResultV := Base64.ToBase64(TxtOf(Args[1]), BoolOf(Args[2]));
            'B64.TOBASE64(TXT,ENC)':
                ResultV := Base64.ToBase64(TxtOf(Args[1]), EncOf(Args[2]));
            'B64.TOBASE64(TXT,ENC,INT)':
                ResultV := Base64.ToBase64(TxtOf(Args[1]), EncOf(Args[2]), IntOf(Args[3]));
            'B64.TOBASE64(TXT,BOOL,ENC,INT)':
                ResultV := Base64.ToBase64(TxtOf(Args[1]), BoolOf(Args[2]), EncOf(Args[3]), IntOf(Args[4]));
            'B64.TOBASE64(INS)':
                begin
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    ResultV := Base64.ToBase64(InS);
                end;
            'B64.TOBASE64(INS,BOOL)':
                begin
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    ResultV := Base64.ToBase64(InS, BoolOf(Args[2]));
                end;
            'B64.TOBASE64URL(TXT)':
                ResultV := Base64.ToBase64Url(TxtOf(Args[1]));
            'B64.TOBASE64URL(TXT,ENC)':
                ResultV := Base64.ToBase64Url(TxtOf(Args[1]), EncOf(Args[2]));
            'B64.TOBASE64URL(TXT,ENC,INT)':
                ResultV := Base64.ToBase64Url(TxtOf(Args[1]), EncOf(Args[2]), IntOf(Args[3]));
            'B64.TOBASE64URL(INS)':
                begin
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    ResultV := Base64.ToBase64Url(InS);
                end;
            'B64.FROMBASE64(TXT)':
                ResultV := Base64.FromBase64(TxtOf(Args[1]));
            'B64.FROMBASE64(TXT,ENC)':
                ResultV := Base64.FromBase64(TxtOf(Args[1]), EncOf(Args[2]));
            'B64.FROMBASE64(TXT,ENC,INT)':
                ResultV := Base64.FromBase64(TxtOf(Args[1]), EncOf(Args[2]), IntOf(Args[3]));
            'B64.FROMBASE64(TXT,OUTS)':
                begin
                    StrmRt.GetOut(IntOf(Args[2]), OutS);
                    Base64.FromBase64(TxtOf(Args[1]), OutS);
                end;

            // --- codeunit 710 Math ---
            'MATH.PI()':
                ResultV := MathCU.Pi();
            'MATH.E()':
                ResultV := MathCU.E();
            'MATH.ABS(DEC)':
                ResultV := MathCU.Abs(DecOf(Args[1]));
            'MATH.ACOS(DEC)':
                ResultV := MathCU.Acos(DecOf(Args[1]));
            'MATH.ASIN(DEC)':
                ResultV := MathCU.Asin(DecOf(Args[1]));
            'MATH.ATAN(DEC)':
                ResultV := MathCU.Atan(DecOf(Args[1]));
            'MATH.ATAN2(DEC,DEC)':
                ResultV := MathCU.Atan2(DecOf(Args[1]), DecOf(Args[2]));
            'MATH.BIGMUL(INT,INT)':
                ResultV := MathCU.BigMul(IntOf(Args[1]), IntOf(Args[2]));
            'MATH.CEILING(DEC)':
                ResultV := MathCU.Ceiling(DecOf(Args[1]));
            'MATH.COS(DEC)':
                ResultV := MathCU.Cos(DecOf(Args[1]));
            'MATH.COSH(DEC)':
                ResultV := MathCU.Cosh(DecOf(Args[1]));
            'MATH.EXP(DEC)':
                ResultV := MathCU.Exp(DecOf(Args[1]));
            'MATH.FLOOR(DEC)':
                ResultV := MathCU.Floor(DecOf(Args[1]));
            'MATH.IEEEREMAINDER(DEC,DEC)':
                ResultV := MathCU.IEEERemainder(DecOf(Args[1]), DecOf(Args[2]));
            'MATH.LOG(DEC)':
                ResultV := MathCU.Log(DecOf(Args[1]));
            'MATH.LOG(DEC,DEC)':
                ResultV := MathCU.Log(DecOf(Args[1]), DecOf(Args[2]));
            'MATH.LOG10(DEC)':
                ResultV := MathCU.Log10(DecOf(Args[1]));
            'MATH.MAX(DEC,DEC)':
                ResultV := MathCU."Max"(DecOf(Args[1]), DecOf(Args[2]));
            'MATH.MIN(DEC,DEC)':
                ResultV := MathCU."Min"(DecOf(Args[1]), DecOf(Args[2]));
            'MATH.POW(DEC,DEC)':
                ResultV := MathCU.Pow(DecOf(Args[1]), DecOf(Args[2]));
            'MATH.SIGN(DEC)':
                ResultV := MathCU.Sign(DecOf(Args[1]));
            'MATH.SINH(DEC)':
                ResultV := MathCU.Sinh(DecOf(Args[1]));
            'MATH.SIN(DEC)':
                ResultV := MathCU.Sin(DecOf(Args[1]));
            'MATH.SQRT(DEC)':
                ResultV := MathCU.Sqrt(DecOf(Args[1]));
            'MATH.TAN(DEC)':
                ResultV := MathCU.Tan(DecOf(Args[1]));
            'MATH.TANH(DEC)':
                ResultV := MathCU.Tanh(DecOf(Args[1]));
            'MATH.TRUNCATE(DEC)':
                ResultV := MathCU.Truncate(DecOf(Args[1]));

            // --- codeunit 1486 Encoding ---
            'ENC.CONVERT(INT,INT,TXT)':
                ResultV := EncodingCU.Convert(IntOf(Args[1]), IntOf(Args[2]), TxtOf(Args[3]));

            // --- codeunit 425 "Data Compression" — Args[1] is the instance handle ---
            'DC.CREATEZIPARCHIVE(SELF)':
                DataComp[Inst(Args[1])].CreateZipArchive();
            'DC.OPENZIPARCHIVE(SELF,INS,BOOL)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetIn(IntOf(Args[2]), InS);
                    DataComp[H].OpenZipArchive(InS, BoolOf(Args[3]));
                end;
            'DC.OPENZIPARCHIVE(SELF,INS,BOOL,INT)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetIn(IntOf(Args[2]), InS);
                    DataComp[H].OpenZipArchive(InS, BoolOf(Args[3]), IntOf(Args[4]));
                end;
            'DC.SAVEZIPARCHIVE(SELF,OUTS)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetOut(IntOf(Args[2]), OutS);
                    DataComp[H].SaveZipArchive(OutS);
                end;
            'DC.CLOSEZIPARCHIVE(SELF)':
                DataComp[Inst(Args[1])].CloseZipArchive();
            'DC.GETENTRYLIST(SELF,LIST)':
                begin
                    H := Inst(Args[1]);
                    DataComp[H].GetEntryList(Names);
                    // Native GetEntryList APPENDS to the caller's list (no Clear) — so does this,
                    // in place on the ALI list handle.
                    foreach EntryName in Names do
                        ListRt.Add(IntOf(Args[2]), EntryName);
                end;
            'DC.EXTRACTENTRY(SELF,TXT,OUTS)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetOut(IntOf(Args[3]), OutS);
                    ResultV := DataComp[H].ExtractEntry(TxtOf(Args[2]), OutS);
                end;
            'DC.EXTRACTENTRY(SELF,TXT,OUTS,&INT)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetOut(IntOf(Args[3]), OutS);
                    DataComp[H].ExtractEntry(TxtOf(Args[2]), OutS, Len);
                    Args[4] := Len;
                end;
            'DC.ADDENTRY(SELF,INS,TXT)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetIn(IntOf(Args[2]), InS);
                    DataComp[H].AddEntry(InS, TxtOf(Args[3]));
                end;
            'DC.REMOVEENTRY(SELF,TXT)':
                DataComp[Inst(Args[1])].RemoveEntry(TxtOf(Args[2]));
            'DC.ISGZIP(SELF,INS)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetIn(IntOf(Args[2]), InS);
                    ResultV := DataComp[H].IsGZip(InS);
                end;
            'DC.ISZIP(SELF,INS)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetIn(IntOf(Args[2]), InS);
                    ResultV := DataComp[H].IsZip(InS);
                end;
            'DC.GZIPCOMPRESS(SELF,INS,OUTS)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetIn(IntOf(Args[2]), InS);
                    StrmRt.GetOut(IntOf(Args[3]), OutS);
                    DataComp[H].GZipCompress(InS, OutS);
                end;
            'DC.GZIPDECOMPRESS(SELF,INS,OUTS)':
                begin
                    H := Inst(Args[1]);
                    StrmRt.GetIn(IntOf(Args[2]), InS);
                    StrmRt.GetOut(IntOf(Args[3]), OutS);
                    DataComp[H].GZipDecompress(InS, OutS);
                end;

            // --- codeunit 4100 "Temp Blob" — Args[1] is the instance handle. The stream comes
            // from the real Temp Blob and is re-pointed into the ALI stream handle's slot, so
            // every stream created on one Temp Blob reads/writes that one blob. ---
            'TB.CREATEINSTREAM(SELF,INS)':
                begin
                    TempBlobs[Inst(Args[1])].CreateInStream(InS);
                    StrmRt.AttachIn(IntOf(Args[2]), InS);
                end;
            'TB.CREATEINSTREAM(SELF,INS,ENC)':
                begin
                    TempBlobs[Inst(Args[1])].CreateInStream(InS, EncOf(Args[3]));
                    StrmRt.AttachIn(IntOf(Args[2]), InS);
                end;
            'TB.CREATEOUTSTREAM(SELF,OUTS)':
                begin
                    TempBlobs[Inst(Args[1])].CreateOutStream(OutS);
                    StrmRt.AttachOut(IntOf(Args[2]), OutS);
                end;
            'TB.CREATEOUTSTREAM(SELF,OUTS,ENC)':
                begin
                    TempBlobs[Inst(Args[1])].CreateOutStream(OutS, EncOf(Args[3]));
                    StrmRt.AttachOut(IntOf(Args[2]), OutS);
                end;
            'TB.HASVALUE(SELF)':
                ResultV := TempBlobs[Inst(Args[1])].HasValue();
            'TB.LENGTH(SELF)':
                ResultV := TempBlobs[Inst(Args[1])].Length();
            // Record / RecordRef / FieldRef all ride as Rec Runtime handles (a FieldRef packed
            // with its field number), so the six record overloads share two bridges.
            'TB.FROMRECORD(SELF,REC,INT)', 'TB.FROMRECORD(SELF,RREF,INT)', 'TB.FROMRECORDREF(SELF,RREF,INT)':
                begin
                    H := Inst(Args[1]);
                    RecRt.BlobToTempBlob(IntOf(Args[2]), IntOf(Args[3]), TempBlobs[H]);
                end;
            'TB.TORECORDREF(SELF,RREF,INT)':
                begin
                    H := Inst(Args[1]);
                    RecRt.TempBlobToBlob(IntOf(Args[2]), IntOf(Args[3]), TempBlobs[H]);
                end;
            'TB.FROMFIELDREF(SELF,FREF)':
                begin
                    H := Inst(Args[1]);
                    RecRt.BlobToTempBlob(RecRt.FieldRefRecHandle(IntOf(Args[2])), RecRt.FieldRefFieldNo(IntOf(Args[2])), TempBlobs[H]);
                end;
            'TB.TOFIELDREF(SELF,FREF)':
                begin
                    H := Inst(Args[1]);
                    RecRt.TempBlobToBlob(RecRt.FieldRefRecHandle(IntOf(Args[2])), RecRt.FieldRefFieldNo(IntOf(Args[2])), TempBlobs[H]);
                end;

            // --- codeunit 457 "Environment Information" ---
            'ENV.ISPRODUCTION()':
                ResultV := EnvInfo.IsProduction();
            'ENV.ISSANDBOX()':
                ResultV := EnvInfo.IsSandbox();
            'ENV.ISSAAS()':
                ResultV := EnvInfo.IsSaaS();
            'ENV.ISONPREM()':
                ResultV := EnvInfo.IsOnPrem();
            'ENV.ISFINANCIALS()':
                ResultV := EnvInfo.IsFinancials();
            'ENV.ISSAASINFRASTRUCTURE()':
                ResultV := EnvInfo.IsSaaSInfrastructure();
            'ENV.CANSTARTSESSION()':
                ResultV := EnvInfo.CanStartSession();
            'ENV.GETENVIRONMENTNAME()':
                ResultV := EnvInfo.GetEnvironmentName();
            'ENV.GETAPPLICATIONFAMILY()':
                ResultV := EnvInfo.GetApplicationFamily();
            'ENV.GETLINKEDPOWERPLATFORMENVIRONMENTID()':
                ResultV := EnvInfo.GetLinkedPowerPlatformEnvironmentId();
#if not CLOUD
            'ENV.GETENVIRONMENTSETTING(TXT)':
                ResultV := EnvInfo.GetEnvironmentSetting(TxtOf(Args[1]));
#endif
            'ENV.VERSIONINSTALLED(GUID)':
                ResultV := EnvInfo.VersionInstalled(GuidOf(Args[1]));

            // --- codeunit 43 Language ---
            'LANG.GETUSERLANGUAGECODE()':
                ResultV := LanguageCU.GetUserLanguageCode();
            'LANG.GETUSERLANGUAGETAG()':
                ResultV := LanguageCU.GetUserLanguageTag();
            'LANG.GETDEFAULTAPPLICATIONLANGUAGEID()':
                ResultV := LanguageCU.GetDefaultApplicationLanguageId();
            'LANG.GETCURRENTCULTURENAME()':
                ResultV := LanguageCU.GetCurrentCultureName();
            'LANG.GETLANGUAGEIDORDEFAULT(TXT)':
                ResultV := LanguageCU.GetLanguageIdOrDefault(CopyStr(TxtOf(Args[1]), 1, 10));
            'LANG.GETLANGUAGEID(TXT)':
                ResultV := LanguageCU.GetLanguageId(CopyStr(TxtOf(Args[1]), 1, 10));
            'LANG.GETFORMATREGIONORDEFAULT(TXT)':
                ResultV := LanguageCU.GetFormatRegionOrDefault(CopyStr(TxtOf(Args[1]), 1, 80));
            'LANG.GETLANGUAGECODE(INT)':
                ResultV := LanguageCU.GetLanguageCode(IntOf(Args[1]));
            'LANG.GETWINDOWSLANGUAGENAME(INT)':
                ResultV := LanguageCU.GetWindowsLanguageName(IntOf(Args[1]));
            'LANG.GETWINDOWSLANGUAGENAME(TXT)':
                ResultV := LanguageCU.GetWindowsLanguageName(CopyStr(TxtOf(Args[1]), 1, 10));
            'LANG.GETPARENTLANGUAGEID(INT)':
                ResultV := LanguageCU.GetParentLanguageId(IntOf(Args[1]));
            'LANG.GETTWOLETTERISOLANGUAGENAME(INT)':
                ResultV := LanguageCU.GetTwoLetterISOLanguageName(IntOf(Args[1]));
            'LANG.GETLANGUAGEIDFROMCULTURENAME(TXT)':
                ResultV := LanguageCU.GetLanguageIdFromCultureName(TxtOf(Args[1]));
            'LANG.GETCULTURENAME(INT)':
                ResultV := LanguageCU.GetCultureName(IntOf(Args[1]));
            'LANG.VALIDATEAPPLICATIONLANGUAGEID(INT)':
                LanguageCU.ValidateApplicationLanguageId(IntOf(Args[1]));
            'LANG.VALIDATEWINDOWSLANGUAGEID(INT)':
                LanguageCU.ValidateWindowsLanguageId(IntOf(Args[1]));
            'LANG.TODEFAULTLANGUAGE(VAR)':
                ResultV := LanguageCU.ToDefaultLanguage(Args[1]);
            'LANG.SETOVERRIDELANGUAGEID(INT)':
                LanguageCU.SetOverrideLanguageId(IntOf(Args[1]));
            'LANG.SETOVERRIDELANGUAGEID(INT,BOOL)':
                LanguageCU.SetOverrideLanguageId(IntOf(Args[1]), BoolOf(Args[2]));
            'LANG.SETOVERRIDEFORMATREGION(TXT)':
                LanguageCU.SetOverrideFormatRegion(CopyStr(TxtOf(Args[1]), 1, 80));
            'LANG.SETOVERRIDEFORMATREGION(TXT,BOOL)':
                LanguageCU.SetOverrideFormatRegion(CopyStr(TxtOf(Args[1]), 1, 80), BoolOf(Args[2]));
            'LANG.GETAPPLICATIONLANGUAGES(REC)':
                begin
                    ShareRec(IntOf(Args[1]), TempWinLanguage);
                    LanguageCU.GetApplicationLanguages(TempWinLanguage);
                    AdoptRec(IntOf(Args[1]), TempWinLanguage);
                end;

            // --- codeunit 1266 "Cryptography Management" ---
            'CRY.GENERATEHASH(TXT,INT)':
                ResultV := CryptoMgt.GenerateHash(TxtOf(Args[1]), IntOf(Args[2]));
            'CRY.GENERATEHASH(INS,INT)':
                begin
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    ResultV := CryptoMgt.GenerateHash(InS, IntOf(Args[2]));
                end;
            'CRY.GENERATEHASH(TXT,TXT,INT)':
                begin
                    SecKey := TxtOf(Args[2]);
                    ResultV := CryptoMgt.GenerateHash(TxtOf(Args[1]), SecKey, IntOf(Args[3]));
                end;
            'CRY.GENERATEHASHASBASE64STRING(TXT,INT)':
                ResultV := CryptoMgt.GenerateHashAsBase64String(TxtOf(Args[1]), IntOf(Args[2]));
            'CRY.GENERATEHASHASBASE64STRING(TXT,TXT,INT)':
                begin
                    SecKey := TxtOf(Args[2]);
                    ResultV := CryptoMgt.GenerateHashAsBase64String(TxtOf(Args[1]), SecKey, IntOf(Args[3]));
                end;
            'CRY.GENERATEBASE64KEYEDHASHASBASE64STRING(TXT,TXT,INT)':
                begin
                    SecKey := TxtOf(Args[2]);
                    ResultV := CryptoMgt.GenerateBase64KeyedHashAsBase64String(TxtOf(Args[1]), SecKey, IntOf(Args[3]));
                end;
            'CRY.GENERATEBASE64KEYEDHASH(TXT,TXT,INT)':
                begin
                    SecKey := TxtOf(Args[2]);
                    ResultV := CryptoMgt.GenerateBase64KeyedHash(TxtOf(Args[1]), SecKey, IntOf(Args[3]));
                end;
            'CRY.SIGNDATA(TXT,TXT,INT,OUTS)':
                begin
                    SecKey := TxtOf(Args[2]);
                    StrmRt.GetOut(IntOf(Args[4]), OutS);
                    CryptoMgt.SignData(TxtOf(Args[1]), SecKey, Enum::"Hash Algorithm".FromInteger(IntOf(Args[3])), OutS);
                end;
            'CRY.SIGNDATA(INS,TXT,INT,OUTS)':
                begin
                    SecKey := TxtOf(Args[2]);
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    StrmRt.GetOut(IntOf(Args[4]), OutS);
                    CryptoMgt.SignData(InS, SecKey, Enum::"Hash Algorithm".FromInteger(IntOf(Args[3])), OutS);
                end;
            'CRY.SIGNDATA(TXT,TXT,INT,INT,OUTS)':
                begin
                    SecKey := TxtOf(Args[2]);
                    StrmRt.GetOut(IntOf(Args[5]), OutS);
                    CryptoMgt.SignData(TxtOf(Args[1]), SecKey, Enum::"Hash Algorithm".FromInteger(IntOf(Args[3])), Enum::"RSA Signature Padding".FromInteger(IntOf(Args[4])), OutS);
                end;
            'CRY.VERIFYDATA(TXT,TXT,INT,INS)':
                begin
                    StrmRt.GetIn(IntOf(Args[4]), SigInS);
                    ResultV := CryptoMgt.VerifyData(TxtOf(Args[1]), TxtOf(Args[2]), Enum::"Hash Algorithm".FromInteger(IntOf(Args[3])), SigInS);
                end;
            'CRY.VERIFYDATA(INS,TXT,INT,INS)':
                begin
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    StrmRt.GetIn(IntOf(Args[4]), SigInS);
                    ResultV := CryptoMgt.VerifyData(InS, TxtOf(Args[2]), Enum::"Hash Algorithm".FromInteger(IntOf(Args[3])), SigInS);
                end;

            // --- codeunit 3960 Regex — Args[1] is the instance handle ---
            'RGX.REGEX(SELF,TXT)':
                Regexes[Inst(Args[1])].Regex(TxtOf(Args[2]));
            'RGX.REGEX(SELF,TXT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[3]), TempRegexOptions);
                    Regexes[H].Regex(TxtOf(Args[2]), TempRegexOptions);
                end;
            'RGX.ISMATCH(SELF,TXT)':
                ResultV := Regexes[Inst(Args[1])].IsMatch(TxtOf(Args[2]));
            'RGX.ISMATCH(SELF,TXT,TXT)':
                ResultV := Regexes[Inst(Args[1])].IsMatch(TxtOf(Args[2]), TxtOf(Args[3]));
            'RGX.ISMATCH(SELF,TXT,INT)':
                ResultV := Regexes[Inst(Args[1])].IsMatch(TxtOf(Args[2]), IntOf(Args[3]));
            'RGX.ISMATCH(SELF,TXT,TXT,INT)':
                ResultV := Regexes[Inst(Args[1])].IsMatch(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]));
            'RGX.ISMATCH(SELF,TXT,TXT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[4]), TempRegexOptions);
                    ResultV := Regexes[H].IsMatch(TxtOf(Args[2]), TxtOf(Args[3]), TempRegexOptions);
                end;
            'RGX.ISMATCH(SELF,TXT,TXT,INT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[5]), TempRegexOptions);
                    ResultV := Regexes[H].IsMatch(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), TempRegexOptions);
                end;
            'RGX.MATCH(SELF,TXT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[3]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), TempMatches);
                    AdoptRec(IntOf(Args[3]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,TXT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[4]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), TxtOf(Args[3]), TempMatches);
                    AdoptRec(IntOf(Args[4]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,INT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[4]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), IntOf(Args[3]), TempMatches);
                    AdoptRec(IntOf(Args[4]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,TXT,INT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[5]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), TempMatches);
                    AdoptRec(IntOf(Args[5]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,INT,INT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[5]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), IntOf(Args[3]), IntOf(Args[4]), TempMatches);
                    AdoptRec(IntOf(Args[5]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,TXT,REC,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[4]), TempRegexOptions);
                    ShareRec(IntOf(Args[5]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), TxtOf(Args[3]), TempRegexOptions, TempMatches);
                    AdoptRec(IntOf(Args[5]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,TXT,INT,INT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[6]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), IntOf(Args[5]), TempMatches);
                    AdoptRec(IntOf(Args[6]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,TXT,INT,REC,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[5]), TempRegexOptions);
                    ShareRec(IntOf(Args[6]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), TempRegexOptions, TempMatches);
                    AdoptRec(IntOf(Args[6]), TempMatches);
                end;
            'RGX.MATCH(SELF,TXT,TXT,INT,INT,REC,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[6]), TempRegexOptions);
                    ShareRec(IntOf(Args[7]), TempMatches);
                    Regexes[H].Match(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), IntOf(Args[5]), TempRegexOptions, TempMatches);
                    AdoptRec(IntOf(Args[7]), TempMatches);
                end;
            'RGX.REPLACE(SELF,TXT,TXT)':
                ResultV := Regexes[Inst(Args[1])].Replace(TxtOf(Args[2]), TxtOf(Args[3]));
            'RGX.REPLACE(SELF,TXT,TXT,TXT)':
                ResultV := Regexes[Inst(Args[1])].Replace(TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]));
            'RGX.REPLACE(SELF,TXT,TXT,INT)':
                ResultV := Regexes[Inst(Args[1])].Replace(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]));
            'RGX.REPLACE(SELF,TXT,TXT,TXT,INT)':
                ResultV := Regexes[Inst(Args[1])].Replace(TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]), IntOf(Args[5]));
            'RGX.REPLACE(SELF,TXT,TXT,INT,INT)':
                ResultV := Regexes[Inst(Args[1])].Replace(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), IntOf(Args[5]));
            'RGX.REPLACE(SELF,TXT,TXT,TXT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[5]), TempRegexOptions);
                    ResultV := Regexes[H].Replace(TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]), TempRegexOptions);
                end;
            'RGX.REPLACE(SELF,TXT,TXT,TXT,INT,INT)':
                ResultV := Regexes[Inst(Args[1])].Replace(TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]), IntOf(Args[5]), IntOf(Args[6]));
            'RGX.REPLACE(SELF,TXT,TXT,TXT,INT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[6]), TempRegexOptions);
                    ResultV := Regexes[H].Replace(TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]), IntOf(Args[5]), TempRegexOptions);
                end;
            'RGX.REPLACE(SELF,TXT,TXT,TXT,INT,INT,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[7]), TempRegexOptions);
                    ResultV := Regexes[H].Replace(TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]), IntOf(Args[5]), IntOf(Args[6]), TempRegexOptions);
                end;
            'RGX.SPLIT(SELF,TXT,LIST)':
                begin
                    H := Inst(Args[1]);
                    ListToNative(IntOf(Args[3]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), Names);
                    ListFromNative(IntOf(Args[3]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,TXT,LIST)':
                begin
                    H := Inst(Args[1]);
                    ListToNative(IntOf(Args[4]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), TxtOf(Args[3]), Names);
                    ListFromNative(IntOf(Args[4]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,INT,LIST)':
                begin
                    H := Inst(Args[1]);
                    ListToNative(IntOf(Args[4]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), IntOf(Args[3]), Names);
                    ListFromNative(IntOf(Args[4]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,TXT,INT,LIST)':
                begin
                    H := Inst(Args[1]);
                    ListToNative(IntOf(Args[5]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), Names);
                    ListFromNative(IntOf(Args[5]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,INT,INT,LIST)':
                begin
                    H := Inst(Args[1]);
                    ListToNative(IntOf(Args[5]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), IntOf(Args[3]), IntOf(Args[4]), Names);
                    ListFromNative(IntOf(Args[5]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,TXT,REC,LIST)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[4]), TempRegexOptions);
                    ListToNative(IntOf(Args[5]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), TxtOf(Args[3]), TempRegexOptions, Names);
                    ListFromNative(IntOf(Args[5]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,TXT,INT,INT,LIST)':
                begin
                    H := Inst(Args[1]);
                    ListToNative(IntOf(Args[6]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), IntOf(Args[5]), Names);
                    ListFromNative(IntOf(Args[6]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,TXT,INT,REC,LIST)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[5]), TempRegexOptions);
                    ListToNative(IntOf(Args[6]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), TempRegexOptions, Names);
                    ListFromNative(IntOf(Args[6]), Names);
                end;
            'RGX.SPLIT(SELF,TXT,TXT,INT,INT,REC,LIST)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[6]), TempRegexOptions);
                    ListToNative(IntOf(Args[7]), Names);
                    Regexes[H].Split(TxtOf(Args[2]), TxtOf(Args[3]), IntOf(Args[4]), IntOf(Args[5]), TempRegexOptions, Names);
                    ListFromNative(IntOf(Args[7]), Names);
                end;
            'RGX.ESCAPE(SELF,TXT)':
                ResultV := Regexes[Inst(Args[1])].Escape(TxtOf(Args[2]));
            'RGX.UNESCAPE(SELF,TXT)':
                ResultV := Regexes[Inst(Args[1])].Unescape(TxtOf(Args[2]));
            'RGX.GROUPNAMEFROMNUMBER(SELF,INT)':
                ResultV := Regexes[Inst(Args[1])].GroupNameFromNumber(IntOf(Args[2]));
            'RGX.GROUPNUMBERFROMNAME(SELF,TXT)':
                ResultV := Regexes[Inst(Args[1])].GroupNumberFromName(TxtOf(Args[2]));
            'RGX.GETGROUPNAMES(SELF,LIST)':
                begin
                    H := Inst(Args[1]);
                    ListToNative(IntOf(Args[2]), Names);
                    Regexes[H].GetGroupNames(Names);
                    ListFromNative(IntOf(Args[2]), Names);
                end;
            'RGX.GETCACHESIZE(SELF)':
                ResultV := Regexes[Inst(Args[1])].GetCacheSize();
            'RGX.SETCACHESIZE(SELF,INT)':
                Regexes[Inst(Args[1])].SetCacheSize(IntOf(Args[2]));
            'RGX.GETHASHCODE(SELF)':
                ResultV := Regexes[Inst(Args[1])].GetHashCode();
            'RGX.GROUPS(SELF,REC,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[2]), TempMatches);
                    ShareRec(IntOf(Args[3]), TempGroups);
                    Regexes[H].Groups(TempMatches, TempGroups);
                    AdoptRec(IntOf(Args[3]), TempGroups);
                end;
            'RGX.CAPTURES(SELF,REC,REC)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[2]), TempGroups);
                    ShareRec(IntOf(Args[3]), TempCaptures);
                    Regexes[H].Captures(TempGroups, TempCaptures);
                    AdoptRec(IntOf(Args[3]), TempCaptures);
                end;
            'RGX.MATCHRESULT(SELF,REC,TXT)':
                begin
                    H := Inst(Args[1]);
                    ShareRec(IntOf(Args[2]), TempMatches);
                    ResultV := Regexes[H].MatchResult(TempMatches, TxtOf(Args[3]));
                end;

            // --- Static `Page.Run` / `Report.Run` (pseudo codeunit ids). The record goes over as
            // a Variant built from the handle's RecordRef — the same bridge `Codeunit.Run(id, Rec)`
            // uses, since native AL takes no RecordRef where a record is expected. ---
            'PAGE.RUN(INT)':
                Page.Run(ObjIdOf(Args[1]));
            'PAGE.RUN(INT,REC)':
                begin
                    RecRt.RecordAsVariant(IntOf(Args[2]), V);
                    Page.Run(ObjIdOf(Args[1]), V);
                end;
            'PAGE.RUN(INT,REC,INT)':
                begin
                    RecRt.RecordAsVariant(IntOf(Args[2]), V);
                    Page.Run(ObjIdOf(Args[1]), V, IntOf(Args[3]));
                end;
            'REPORT.RUN(INT)':
                Report.Run(ObjIdOf(Args[1]));
            'REPORT.RUN(INT,BOOL)':
                Report.Run(ObjIdOf(Args[1]), BoolOf(Args[2]));
            'REPORT.RUN(INT,BOOL,BOOL)':
                Report.Run(ObjIdOf(Args[1]), BoolOf(Args[2]), BoolOf(Args[3]));
            'REPORT.RUN(INT,BOOL,BOOL,REC)':
                begin
                    RecRt.RecordAsVariant(IntOf(Args[4]), V);
                    Report.Run(ObjIdOf(Args[1]), BoolOf(Args[2]), BoolOf(Args[3]), V);
                end;

            // --- `File.DownloadFromStream` / `File.UploadIntoStream`. The uploaded stream is
            // re-pointed into the script's InStream handle (AttachIn, as TB.CreateInStream); the
            // file name the dialog returns is written back into Args[i] (`var` column). ---
            'FILE.DOWNLOADFROMSTREAM(INS,TXT,TXT,TXT,&TXT)':
                begin
                    StrmRt.GetIn(IntOf(Args[1]), InS);
                    T := Args[5];
                    ResultV := DownloadFromStream(InS, TxtOf(Args[2]), TxtOf(Args[3]), TxtOf(Args[4]), T);
                    Args[5] := T;
                end;
            'FILE.UPLOADINTOSTREAM(TXT,INS)':
                begin
                    ResultV := UploadIntoStream(TxtOf(Args[1]), InS);
                    StrmRt.AttachIn(IntOf(Args[2]), InS);
                end;
            'FILE.UPLOADINTOSTREAM(TXT,TXT,TXT,&TXT,INS)':
                begin
                    T := Args[4];
                    ResultV := UploadIntoStream(TxtOf(Args[1]), TxtOf(Args[2]), TxtOf(Args[3]), T, InS);
                    Args[4] := T;
                    StrmRt.AttachIn(IntOf(Args[5]), InS);
                end;
            else
                Error('ALI980: ''%1'' is not a catalogued native procedure', DispatchKey);
        end;
    end;

    // ===== Record / List argument bridges =====

    // ShareRec: the native Record var shares ALI record H's temporary dataset (and takes its
    // current row + filters). AdoptRec: the row the native call left current goes back to H.
    // One overload per catalogued table — SetTable/GetTable need a typed Record.
    local procedure ShareRec(H: Integer; var Rec: Record Matches)
    var
        RecRef: RecordRef;
    begin
        RecRt.ShareTempRef(H, RecRef);
        RecRef.SetTable(Rec, true);
    end;

    local procedure ShareRec(H: Integer; var Rec: Record Groups)
    var
        RecRef: RecordRef;
    begin
        RecRt.ShareTempRef(H, RecRef);
        RecRef.SetTable(Rec, true);
    end;

    local procedure ShareRec(H: Integer; var Rec: Record Captures)
    var
        RecRef: RecordRef;
    begin
        RecRt.ShareTempRef(H, RecRef);
        RecRef.SetTable(Rec, true);
    end;

    local procedure ShareRec(H: Integer; var Rec: Record "Regex Options")
    var
        RecRef: RecordRef;
    begin
        RecRt.ShareTempRef(H, RecRef);
        RecRef.SetTable(Rec, true);
    end;

    local procedure ShareRec(H: Integer; var Rec: Record "Windows Language" temporary)
    var
        RecRef: RecordRef;
    begin
        RecRt.ShareTempRef(H, RecRef);
        RecRef.SetTable(Rec, true);
    end;

    local procedure AdoptRec(H: Integer; var Rec: Record Matches)
    var
        RecRef: RecordRef;
    begin
        RecRef.GetTable(Rec);
        RecRt.AdoptTempRef(H, RecRef);
    end;

    local procedure AdoptRec(H: Integer; var Rec: Record Groups)
    var
        RecRef: RecordRef;
    begin
        RecRef.GetTable(Rec);
        RecRt.AdoptTempRef(H, RecRef);
    end;

    local procedure AdoptRec(H: Integer; var Rec: Record Captures)
    var
        RecRef: RecordRef;
    begin
        RecRef.GetTable(Rec);
        RecRt.AdoptTempRef(H, RecRef);
    end;

    local procedure AdoptRec(H: Integer; var Rec: Record "Windows Language" temporary)
    var
        RecRef: RecordRef;
    begin
        RecRef.GetTable(Rec);
        RecRt.AdoptTempRef(H, RecRef);
    end;

    // A `var List of [Text]` argument: the native call sees the list's current content and the
    // result replaces it — exact whether the native procedure clears or appends.
    local procedure ListToNative(ListH: Integer; var Items: List of [Text])
    var
        i: Integer;
    begin
        Clear(Items);
        for i := 1 to ListRt.Count(ListH) do
            Items.Add(TxtOf(ListRt.Get(ListH, i)));
    end;

    local procedure ListFromNative(ListH: Integer; Items: List of [Text])
    var
        Item: Text;
    begin
        ListRt.ClearList(ListH);
        foreach Item in Items do
            ListRt.Add(ListH, Item);
    end;

    // ===== Variant unboxing — typed locals so every overloaded native call resolves statically =====

    local procedure GuidOf(V: Variant): Guid
    begin
        exit(V);
    end;

    local procedure TxtOf(V: Variant): Text
    begin
        exit(V);
    end;

    local procedure IntOf(V: Variant): Integer
    begin
        exit(V);
    end;

    // Page / Report number. 0 and negatives are not objects: say so here rather than let the
    // platform open a nameless page or report.
    local procedure ObjIdOf(V: Variant): Integer
    var
        ObjId: Integer;
    begin
        ObjId := V;
        if ObjId <= 0 then
            Error('ALI1003: %1 is not a page or report id', ObjId);
        exit(ObjId);
    end;

    local procedure BigIntOf(V: Variant): BigInteger
    begin
        exit(V);
    end;

    local procedure DecOf(V: Variant): Decimal
    begin
        exit(V);
    end;

    local procedure BoolOf(V: Variant): Boolean
    begin
        exit(V);
    end;

    local procedure DateOf(V: Variant): Date
    begin
        exit(V);
    end;

    local procedure DTOf(V: Variant): DateTime
    begin
        exit(V);
    end;

    // TextEncoding travels as its ordinal (ALI's Option register) — same mapping as
    // "ALI Stream Runtime".CreateInSlot.
    local procedure EncOf(V: Variant): TextEncoding
    begin
        case IntOf(V) of
            1:
                exit(TextEncoding::UTF8);
            2:
                exit(TextEncoding::UTF16);
            3:
                exit(TextEncoding::Windows);
        end;
        exit(TextEncoding::MSDos);
    end;
}
