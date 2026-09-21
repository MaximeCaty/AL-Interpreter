// ALI Stream Runtime — InStream/OutStream RefShim execution (§19.7, M6).
//
// Stream variables are Int-handle reference values (Handle Lifecycle Unification: same
// scheme as List/Dictionary/Record/TextBuilder/Dialog, §7.1 RegClassFor -> RegClassInt) — the
// runtime owns the backing storage in its own bank, keyed by that handle.
//
// Backing: each stream is backed by a real temp Blob (System Application "Temp Blob"), so
// the streams are genuine native InStream/OutStream instances — this is what makes them
// usable by hand-written native shims (§18.4, e.g. Data Compression) later. An OutStream
// and a linked InStream share the SAME backing Blob so an OutStream write is readable
// through the InStream (round-trip).
//
// IMPLEMENTATION NOTE: the stream slots are plain arrays (StreamCapacity entries) indexed by
// handle. An OutStream must persist across successive writes (re-creating it would reset the
// write position), which an array element does — a stream var is stored, not re-derived. This
// replaced a bank of 32 discrete IS1../OS1.. variables plus a 16-way case in every operation.
//
// Handle Lifecycle Unification: NewStream()/FreeStream() replace the old binder-sealed
// Allocate(N) — a stream var now gets a fresh handle at whichever proc entry declares it
// (global or local), freed (and its discrete slot recycled via FreeIdx) on frame pop.
//
// M6 supported ops (§19.7): OutStream WriteText / WriteLine / Write; InStream ReadText /
// Read / EOS / Length; plus Link(in <- out) to share a backing for a round-trip. SingleInstance so the
// backings survive the dispatch loop; Reset() by the interpreter.
codeunit 51117 "ALI Stream Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        Backing: array[16] of Codeunit "Temp Blob";
        IsOut: array[16] of Boolean;
        Opened: array[16] of Boolean;
        Ins: array[16] of InStream;          // handle -> read slot
        BackingOf: array[16] of Integer;     // handle -> backing slot (shared by a linked pair), 0 = a Temp Blob's stream
        HandleCount: Integer;
        FreeIdx: List of [Integer];
        Outs: array[16] of OutStream;        // handle -> write slot

    procedure Reset()
    begin
        Clear(Backing);
        Clear(Ins);
        Clear(Outs);
        Clear(IsOut);
        Clear(Opened);
        Clear(BackingOf);
        HandleCount := 0;
        Clear(FreeIdx);
    end;

    local procedure StreamCapacity(): Integer
    begin
        exit(16);
    end;

    // Handle Lifecycle Unification: allocate (or reuse) a fresh stream handle and open it —
    // mirrors "ALI List Runtime".NewList. Out = true opens an OutStream, false an InStream.
    procedure NewStream(Out: Boolean): Integer
    var
        H: Integer;
    begin
        if FreeIdx.Count() > 0 then begin
            H := FreeIdx.Get(FreeIdx.Count());
            FreeIdx.RemoveAt(FreeIdx.Count());
        end else begin
            HandleCount += 1;
            if HandleCount > StreamCapacity() then
                Error('ALI963: too many concurrently live stream variables (max %1)', StreamCapacity());
            H := HandleCount;
        end;
        OpenStream(H, Out);
        exit(H);
    end;

    // Reclaim a stream handle — recycles its discrete slot for NewStream() to reuse. The
    // backing Temp Blob at slot H is cleared when the handle is reopened, not here: a linked
    // InStream still reading it keeps its native stream (which holds the content).
    procedure FreeStream(H: Integer)
    var
        RecRt: Codeunit "ALI Rec Runtime";
    begin
        if (H < 1) or (H > HandleCount) then
            exit;
        // Push any pending blob write into its record BEFORE the handle is marked closed —
        // BlobToRecordRef guards on the stream being open, and the backing buffer is still
        // intact here. An OutStream dying is not a reason to lose what was written through it
        // (native AL writes through to the record's blob field); see
        // "ALI Rec Runtime".FlushPendingBlobStream. The association is dropped either way, so a
        // later Insert/Modify can never push a recycled stream's content into a blob field.
        RecRt.FlushPendingBlobStream(H);
        Opened[H] := false;
        FreeIdx.Add(H);
    end;

    // Open handle H as an OutStream (Out=true) or InStream over a FRESH backing Blob. The backing
    // slot is the handle's own (like the blob bridges below): a run-wide counter here used to
    // index past the 16 backings on the 17th stream allocation, e.g. a proc with a local stream
    // called in a loop.
    local procedure OpenStream(H: Integer; Out: Boolean)
    begin
        GuardHandle(H);
        Clear(Backing[H]);
        BackingOf[H] := H;
        IsOut[H] := Out;
        if Out then
            CreateOutSlot(H, H, 0)
        else
            CreateInSlot(H, H, 0);
        Opened[H] := true;
    end;

    // Link an InStream handle to read from the SAME backing an OutStream handle wrote to.
    // Enc: TextEncoding ordinal for the read side (0 MSDos/default, 1 UTF8, 2 UTF16, 3 Windows).
    procedure LinkInToOut(InH: Integer; OutH: Integer; Enc: Integer)
    begin
        GuardHandle(InH);
        GuardHandle(OutH);
        if BackingOf[OutH] = 0 then
            Error('ALI965: Link needs an OutStream ALI owns — this one was created by a Temp Blob; read it back with that Temp Blob''s CreateInStream');
        BackingOf[InH] := BackingOf[OutH];
        IsOut[InH] := false;
        CreateInSlot(InH, BackingOf[OutH], Enc);
        Opened[InH] := true;
    end;

    // ===== Temp Blob bridging ("ALI Native Runtime", TempBlob.CreateInStream / CreateOutStream) =====
    //
    // The native stream comes from the script's real Temp Blob and simply takes over handle H's
    // slot (a stream assignment shares the underlying stream). BackingOf[H] = 0: the content
    // belongs to that Temp Blob, not to a backing of this runtime. A pending Rec.Blob write
    // parked on H is flushed first, as BlobCreateOutStream does.

    procedure AttachIn(H: Integer; S: InStream)
    var
        RecRt: Codeunit "ALI Rec Runtime";
    begin
        GuardHandle(H);
        RecRt.FlushPendingBlobStream(H);
        Ins[H] := S;
        BackingOf[H] := 0;
        IsOut[H] := false;
        Opened[H] := true;
    end;

    procedure AttachOut(H: Integer; S: OutStream)
    var
        RecRt: Codeunit "ALI Rec Runtime";
    begin
        GuardHandle(H);
        RecRt.FlushPendingBlobStream(H);
        Outs[H] := S;
        BackingOf[H] := 0;
        IsOut[H] := true;
        Opened[H] := true;
    end;

    // ===== BLOB field bridging (Rec.MyBlob.CreateInStream / CreateOutStream) =====
    //
    // These re-point an ALREADY allocated stream handle (streams get their handle at proc
    // entry) at the record's blob content, using the handle's own backing slot — no
    // BackingCount bump, so repeated blob opens in a loop cannot run the backing array out.

    // Read a record's blob: refill H's backing from the record field and open H over it.
    // Enc: TextEncoding ordinal (0 MSDos/default, 1 UTF8, 2 UTF16, 3 Windows).
    procedure AttachInFromRecordRef(H: Integer; RecRef: RecordRef; FieldNo: Integer; Enc: Integer)
    begin
        GuardHandle(H);
        Clear(Backing[H]);
        Backing[H].FromRecordRef(RecRef, FieldNo);
        BackingOf[H] := H;
        IsOut[H] := false;
        CreateInSlot(H, H, Enc);
        Opened[H] := true;
    end;

    // Write a record's blob: open H for writing over a cleared backing. The content reaches
    // the record at Insert/Modify time (see "ALI Rec Runtime".FlushPendingBlobs).
    procedure ReopenOutEmpty(H: Integer; Enc: Integer)
    begin
        GuardHandle(H);
        Clear(Backing[H]);
        BackingOf[H] := H;
        IsOut[H] := true;
        CreateOutSlot(H, H, Enc);
        Opened[H] := true;
    end;

    // Push what was written through handle H into RecRef's blob field.
    procedure BlobToRecordRef(H: Integer; var RecRef: RecordRef; FieldNo: Integer)
    begin
        GuardHandle(H);
        Backing[BackingOf[H]].ToRecordRef(RecRef, FieldNo);
    end;

    // ===== OutStream ops =====

    procedure WriteText(H: Integer; Value: Text)
    begin
        GuardOut(H);
        Outs[H].WriteText(Value);
    end;

    // WriteText(Value, Length) — native truncates/pads to Length.
    procedure WriteTextN(H: Integer; Value: Text; Len: Integer)
    begin
        GuardOut(H);
        Outs[H].WriteText(Value, Len);
    end;

    // WriteText() with no argument — native writes the line terminator only.
    procedure WriteNewLine(H: Integer)
    begin
        GuardOut(H);
        Outs[H].WriteText();
    end;

    procedure WriteLine(H: Integer; Value: Text)
    begin
        GuardOut(H);
        Outs[H].WriteText(Value);
        Outs[H].WriteText();
    end;

    // ===== Native Read/Write (typed binary I/O) =====
    //
    // Native AL InStream.Read(Var) / OutStream.Write(Var) are TYPE-DIRECTED: the byte layout
    // depends on the variable's declared type. So the encoding is NOT re-implemented here —
    // the runtime dispatches on the ALI TypeKind ordinal and hands a real typed local to the
    // native call, which keeps the on-stream bytes identical to native AL (and keeps a
    // Write/Read pair round-trip-exact). TypeOrd 71 (Variant) is passed straight through, so
    // whatever native does with a Variant (including its own error) is what the script sees.
    // Both return the native byte count.

    procedure WriteValue(H: Integer; TypeOrd: Integer; Value: Variant): Integer
    var
        BigV: BigInteger;
        BoolV: Boolean;
        DateV: Date;
        DtV: DateTime;
        DecV: Decimal;
        DurV: Duration;
        GuidV: Guid;
        IntV: Integer;
        TxtV: Text;
        TimeV: Time;
    begin
        GuardOut(H);
        case TypeOrd of
            10, 40, 41:     // Integer / Option / Enum — Int-backed
                begin
                    IntV := Value;
                    exit(Outs[H].Write(IntV));
                end;
            11:             // BigInteger
                begin
                    BigV := Value;
                    exit(Outs[H].Write(BigV));
                end;
            12:             // Decimal
                begin
                    DecV := Value;
                    exit(Outs[H].Write(DecV));
                end;
            20:             // Boolean
                begin
                    BoolV := Value;
                    exit(Outs[H].Write(BoolV));
                end;
            30, 31, 32:     // Text / Code / Label
                begin
                    TxtV := Value;
                    exit(Outs[H].Write(TxtV));
                end;
            50:             // Date
                begin
                    DateV := Value;
                    exit(Outs[H].Write(DateV));
                end;
            51:             // Time
                begin
                    TimeV := Value;
                    exit(Outs[H].Write(TimeV));
                end;
            52:             // DateTime
                begin
                    DtV := Value;
                    exit(Outs[H].Write(DtV));
                end;
            53:             // Duration
                begin
                    DurV := Value;
                    exit(Outs[H].Write(DurV));
                end;
            60:             // Guid
                begin
                    GuidV := Value;
                    exit(Outs[H].Write(GuidV));
                end;
            71:             // Variant — native pass-through
                exit(Outs[H].Write(Value));
            else
                Error('ALI969: Write is not supported for this value type (TypeKind %1)', TypeOrd);
        end;
    end;

    // Len < 0 = no Length argument (native Read(var X)); otherwise native Read(var X, Len).
    procedure ReadValue(H: Integer; TypeOrd: Integer; Len: Integer; var Value: Variant): Integer
    var
        BigV: BigInteger;
        ByteV: Byte;
        DateV: Date;
        DtV: DateTime;
        DecV: Decimal;
        DurV: Duration;
        GuidV: Guid;
        Bytes: Integer;
        IntV: Integer;
        TxtV: Text;
        TimeV: Time;
    begin
        GuardIn(H);
        case TypeOrd of
            10, 40, 41:     // Integer / Option / Enum
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(IntV)
                    else
                        Bytes := Ins[H].Read(IntV, Len);
                    Value := IntV;
                end;
            11:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(BigV)
                    else
                        Bytes := Ins[H].Read(BigV, Len);
                    Value := BigV;
                end;
            12:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(DecV)
                    else
                        Bytes := Ins[H].Read(DecV, Len);
                    Value := DecV;
                end;
            20:     // Boolean: native Read(var Boolean) is AMBIGUOUS against Read(var Byte)
                    // (AL0196), so the single byte a Boolean Write emits is read back as a Byte
                    // and re-typed here — same bytes on the stream either way.
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(ByteV)
                    else
                        Bytes := Ins[H].Read(ByteV, Len);
                    Value := ByteV <> 0;
                end;
            30, 31, 32:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(TxtV)
                    else
                        Bytes := Ins[H].Read(TxtV, Len);
                    Value := TxtV;
                end;
            50:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(DateV)
                    else
                        Bytes := Ins[H].Read(DateV, Len);
                    Value := DateV;
                end;
            51:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(TimeV)
                    else
                        Bytes := Ins[H].Read(TimeV, Len);
                    Value := TimeV;
                end;
            52:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(DtV)
                    else
                        Bytes := Ins[H].Read(DtV, Len);
                    Value := DtV;
                end;
            53:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(DurV)
                    else
                        Bytes := Ins[H].Read(DurV, Len);
                    Value := DurV;
                end;
            60:
                begin
                    if Len < 0 then
                        Bytes := Ins[H].Read(GuidV)
                    else
                        Bytes := Ins[H].Read(GuidV, Len);
                    Value := GuidV;
                end;
            else
                // No Variant arm: native Read(var Any) cannot resolve an overload from a
                // Variant target (AL0196), exactly as in native AL — the binder rejects a
                // Variant target up front, this is the belt-and-braces arm.
                Error('ALI969: Read is not supported for this target type (TypeKind %1)', TypeOrd);
        end;
        exit(Bytes);
    end;

    // ===== InStream ops =====

    procedure ReadText(H: Integer; var Result: Text): Integer
    begin
        GuardIn(H);
        exit(Ins[H].ReadText(Result));
    end;

    // ReadText(Text, Length) — native reads at most Len characters.
    procedure ReadTextN(H: Integer; Len: Integer; var Result: Text): Integer
    begin
        GuardIn(H);
        exit(Ins[H].ReadText(Result, Len));
    end;

    // ===== Positioning (InStream only — native OutStream has no Position/ResetPosition) =====

    procedure GetPosition(H: Integer): Integer
    begin
        GuardIn(H);
        exit(Ins[H].Position());
    end;

    procedure SetPosition(H: Integer; Pos: Integer)
    begin
        GuardIn(H);
        Ins[H].Position(Pos);
    end;

    procedure ResetPos(H: Integer)
    begin
        GuardIn(H);
        Ins[H].ResetPosition();
    end;

    procedure EndOfStream(H: Integer): Boolean
    begin
        GuardIn(H);
        exit(Ins[H].EOS());
    end;

    procedure StreamLength(H: Integer): Integer
    begin
        GuardHandle(H);
        if BackingOf[H] = 0 then begin
            GuardIn(H);                     // a Temp Blob's stream: only an InStream knows its length
            exit(Ins[H].Length());
        end;
        exit(Backing[BackingOf[H]].Length());
    end;

    // CopyStream(OutStream, InStream [, ByteToRead]). UseBytes selects the 3-arg overload.
    procedure CopyStreamTo(OutH: Integer; InH: Integer; Bytes: Integer; UseBytes: Boolean): Boolean
    begin
        GuardOut(OutH);
        GuardIn(InH);
        if UseBytes then
            exit(CopyStream(Outs[OutH], Ins[InH], Bytes));
        exit(CopyStream(Outs[OutH], Ins[InH]));
    end;

    // Native codeunit calls ("ALI Native Runtime") need the handle's NATIVE stream. A stream
    // assignment shares the underlying stream (reading through the copy advances the slot too),
    // so handing a copy out through a `var` is enough — no per-callee delegation like the Xml
    // bridges below.
    procedure GetIn(H: Integer; var S: InStream)
    begin
        GuardIn(H);
        S := Ins[H];
    end;

    procedure GetOut(H: Integer; var S: OutStream)
    begin
        GuardOut(H);
        S := Outs[H];
    end;

    // ===== Feature 3: Xml stream bridges (XML_DESIGN.md §7.3) =====
    //
    // XmlDocument.ReadFrom(InStream, ...) / node WriteTo(OutStream, ...) need the NATIVE
    // stream of a handle, but the slot bank is private and AL cannot return a stream — so
    // this runtime hosts the calls and passes its slot `var` to the Xml runtime
    // (AttachInFromRecordRef precedent). OptH is an "ALI Xml Runtime" bank handle
    // (XmlWriteOptions/XmlReadOptions); UseOpt selects the options overload.

    procedure XmlWriteNode(H: Integer; NodeH: Integer; OptH: Integer; UseOpt: Boolean): Boolean
    var
        XmlRt: Codeunit "ALI Xml Runtime";
    begin
        GuardOut(H);
        if UseOpt then
            exit(XmlRt.NodeWriteToStreamOpt(NodeH, OptH, Outs[H]));
        exit(XmlRt.NodeWriteToStream(NodeH, Outs[H]));
    end;

    procedure XmlReadDoc(H: Integer; OptH: Integer; UseOpt: Boolean; OutDocH: Integer): Boolean
    var
        XmlRt: Codeunit "ALI Xml Runtime";
    begin
        GuardIn(H);
        if UseOpt then
            exit(XmlRt.DocReadFromStreamOpt(Ins[H], OptH, OutDocH));
        exit(XmlRt.DocReadFromStream(Ins[H], OutDocH));
    end;

    // BigText.Read(InStream) / BigText.Write(OutStream) and Media.ExportStream(OutStream) —
    // same delegation shape as the Xml entry points above: the caller owns the object, this
    // runtime owns the only native stream and passes its slot `var`.

    procedure BigTextRead(H: Integer; BtH: Integer)
    var
        BigRt: Codeunit "ALI BigText Runtime";
    begin
        GuardIn(H);
        BigRt.ReadFromStream(BtH, Ins[H]);
    end;

    procedure BigTextWrite(H: Integer; BtH: Integer)
    var
        BigRt: Codeunit "ALI BigText Runtime";
    begin
        GuardOut(H);
        BigRt.WriteToStream(BtH, Outs[H]);
    end;

    // Media.ExportStream(OutStream): copy the media payload out of Tenant Media (where the
    // platform stores it) — the only route available when the field was reached by FieldRef and
    // so is a GUID rather than a native Media object. A blank/unknown id writes nothing.
    procedure MediaExport(H: Integer; MediaId: Guid)
    var
        TenantMedia: Record "Tenant Media";
        Src: InStream;
    begin
        GuardOut(H);
        if IsNullGuid(MediaId) then
            exit;
        if not TenantMedia.Get(MediaId) then
            exit;
        TenantMedia.CalcFields(Content);
        if not TenantMedia.Content.HasValue() then
            exit;
        TenantMedia.Content.CreateInStream(Src);
        CopyStream(Outs[H], Src);
    end;

    // ===== Slot creation =====

    local procedure CreateOutSlot(H: Integer; B: Integer; Enc: Integer)
    begin
        case Enc of
            1:
                Backing[B].CreateOutStream(Outs[H], TextEncoding::UTF8);
            2:
                Backing[B].CreateOutStream(Outs[H], TextEncoding::UTF16);
            3:
                Backing[B].CreateOutStream(Outs[H], TextEncoding::Windows);
            else
                Backing[B].CreateOutStream(Outs[H], TextEncoding::MSDos);
        end;
    end;

    local procedure CreateInSlot(H: Integer; B: Integer; Enc: Integer)
    begin
        case Enc of
            1:
                Backing[B].CreateInStream(Ins[H], TextEncoding::UTF8);
            2:
                Backing[B].CreateInStream(Ins[H], TextEncoding::UTF16);
            3:
                Backing[B].CreateInStream(Ins[H], TextEncoding::Windows);
            else
                Backing[B].CreateInStream(Ins[H], TextEncoding::MSDos);
        end;
    end;

    // ===== Guards =====

    local procedure GuardHandle(H: Integer)
    begin
        if (H < 1) or (H > StreamCapacity()) then
            Error('ALI964: stream handle %1 out of range', H);
    end;

    local procedure GuardOut(H: Integer)
    begin
        GuardHandle(H);
        if not Opened[H] then
            Error('ALI965: stream used before it was opened (handle %1)', H);
        if not IsOut[H] then
            Error('ALI966: cannot write to an InStream (handle %1)', H);
    end;

    local procedure GuardIn(H: Integer)
    begin
        GuardHandle(H);
        if not Opened[H] then
            Error('ALI965: stream used before it was opened (handle %1)', H);
        if IsOut[H] then
            Error('ALI967: cannot read from an OutStream (handle %1)', H);
    end;
}
