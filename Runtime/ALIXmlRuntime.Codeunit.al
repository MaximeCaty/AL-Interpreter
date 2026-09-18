// ALI Xml Runtime — full AL Xml* datatype family RefShim execution (Feature 3, XML_DESIGN.md §8).
//
// An Xml* VALUE is an Int handle (RegClassInt) — same scheme as Json* (see "ALI Json Runtime"
// header). The 10 node kinds (XmlDocument/XmlNode/XmlElement/XmlAttribute/XmlComment/XmlCData/
// XmlDeclaration/XmlDocumentType/XmlText/XmlProcessingInstruction) share ONE bank: `List of
// [XmlNode]` — every node kind round-trips AsXmlNode()/AsXml<Kind>() (verified probe, design
// doc header), and native Xml* types are reference-type wrappers over the same DOM, so a
// List.Get copy aliases the DOM with whatever wrote it (mutation through one alias visible
// through another — the Json TokBank argument, no box-codeunit indirection needed).
// XmlNodeList / XmlAttributeCollection / XmlNamespaceManager / XmlReadOptions / XmlWriteOptions
// / XmlNameTable each get their own bank (distinct native types, no common supertype).
//
// Storage convention: a node handle's slot always holds an XmlNode (AsXmlNode() at store time);
// per-kind narrowing via AsXml<Kind>() on access, which Errors natively on a kind mismatch —
// mirrors native As* runtime-error behavior, no extra guard (§8 caveat: methods on a
// never-assigned Xml variable may raise kind-mismatch where native returns defaults; v1).
// XmlReadOptions/XmlWriteOptions/XmlNamespaceManager/XmlAttributeCollection mutators do
// Get → mutate → Set back into the bank slot (value-copy belt-and-suspenders, mirrors the
// Json SetTok write-back note).
codeunit 51086 "ALI Xml Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        AttrColFree: List of [Integer];
        ListFree: List of [Integer];
        NameTableFree: List of [Integer];
        NodeFree: List of [Integer];
        NsMgrFree: List of [Integer];
        ReadOptFree: List of [Integer];
        WriteOptFree: List of [Integer];
        AttrColBank: List of [XmlAttributeCollection];
        NsMgrBank: List of [XmlNamespaceManager];
        NameTableBank: List of [XmlNameTable];
        ContentBuf: List of [XmlNode];   // §6 variadic content buffer (single-threaded, never nested)
        NodeBank: List of [XmlNode];
        ListBank: List of [XmlNodeList];
        ReadOptBank: List of [XmlReadOptions];
        WriteOptBank: List of [XmlWriteOptions];

    procedure Reset()
    begin
        Clear(NodeBank);
        Clear(ListBank);
        Clear(AttrColBank);
        Clear(NsMgrBank);
        Clear(ReadOptBank);
        Clear(WriteOptBank);
        Clear(NameTableBank);
        Clear(NodeFree);
        Clear(ListFree);
        Clear(AttrColFree);
        Clear(NsMgrFree);
        Clear(ReadOptFree);
        Clear(WriteOptFree);
        Clear(NameTableFree);
        Clear(ContentBuf);
    end;

    local procedure Guard(H: Integer; Cnt: Integer; Bank: Text)
    begin
        if (H < 1) or (H > Cnt) then
            Error('ALI975: Xml %1 handle %2 out of range', Bank, H);
    end;

    // ===== Bank plumbing: NewHandle/Free per bank (Json FreeIdx recycling pattern) =====

    procedure NewNodeHandle(N: XmlNode): Integer
    var
        H: Integer;
    begin
        if NodeFree.Count() > 0 then begin
            H := NodeFree.Get(NodeFree.Count());
            NodeFree.RemoveAt(NodeFree.Count());
            NodeBank.Set(H, N);
            exit(H);
        end;
        NodeBank.Add(N);
        exit(NodeBank.Count());
    end;

    procedure NewListHandle(L: XmlNodeList): Integer
    var
        H: Integer;
    begin
        if ListFree.Count() > 0 then begin
            H := ListFree.Get(ListFree.Count());
            ListFree.RemoveAt(ListFree.Count());
            ListBank.Set(H, L);
            exit(H);
        end;
        ListBank.Add(L);
        exit(ListBank.Count());
    end;

    procedure NewAttrColHandle(C: XmlAttributeCollection): Integer
    var
        H: Integer;
    begin
        if AttrColFree.Count() > 0 then begin
            H := AttrColFree.Get(AttrColFree.Count());
            AttrColFree.RemoveAt(AttrColFree.Count());
            AttrColBank.Set(H, C);
            exit(H);
        end;
        AttrColBank.Add(C);
        exit(AttrColBank.Count());
    end;

    procedure NewNameTableHandle(NT: XmlNameTable): Integer
    var
        H: Integer;
    begin
        if NameTableFree.Count() > 0 then begin
            H := NameTableFree.Get(NameTableFree.Count());
            NameTableFree.RemoveAt(NameTableFree.Count());
            NameTableBank.Set(H, NT);
            exit(H);
        end;
        NameTableBank.Add(NT);
        exit(NameTableBank.Count());
    end;

    // "New" blank allocators — compiler-emitted at declaration (New ids 1-16), never
    // user-callable; mirror "ALI Json Runtime".NewObject/NewArray/...
    procedure NewNode(): Integer
    var
        Blank: XmlNode;
    begin
        exit(NewNodeHandle(Blank));
    end;

    procedure NewNodeList(): Integer
    var
        Blank: XmlNodeList;
    begin
        exit(NewListHandle(Blank));
    end;

    procedure NewAttrCol(): Integer
    var
        Blank: XmlAttributeCollection;
    begin
        exit(NewAttrColHandle(Blank));
    end;

    procedure NewNsMgr(): Integer
    var
        H: Integer;
        Blank: XmlNamespaceManager;
    begin
        if NsMgrFree.Count() > 0 then begin
            H := NsMgrFree.Get(NsMgrFree.Count());
            NsMgrFree.RemoveAt(NsMgrFree.Count());
            NsMgrBank.Set(H, Blank);
            exit(H);
        end;
        NsMgrBank.Add(Blank);
        exit(NsMgrBank.Count());
    end;

    procedure NewReadOpt(): Integer
    var
        H: Integer;
        Blank: XmlReadOptions;
    begin
        if ReadOptFree.Count() > 0 then begin
            H := ReadOptFree.Get(ReadOptFree.Count());
            ReadOptFree.RemoveAt(ReadOptFree.Count());
            ReadOptBank.Set(H, Blank);
            exit(H);
        end;
        ReadOptBank.Add(Blank);
        exit(ReadOptBank.Count());
    end;

    procedure NewWriteOpt(): Integer
    var
        H: Integer;
        Blank: XmlWriteOptions;
    begin
        if WriteOptFree.Count() > 0 then begin
            H := WriteOptFree.Get(WriteOptFree.Count());
            WriteOptFree.RemoveAt(WriteOptFree.Count());
            WriteOptBank.Set(H, Blank);
            exit(H);
        end;
        WriteOptBank.Add(Blank);
        exit(WriteOptBank.Count());
    end;

    procedure NewNameTable(): Integer
    var
        Blank: XmlNameTable;
    begin
        exit(NewNameTableHandle(Blank));
    end;

    // ===== Bank accessors (Get/Set per bank; Set = §7.2 var-out REBIND target) =====

    procedure GetNode(H: Integer): XmlNode
    var
        N: XmlNode;
    begin
        Guard(H, NodeBank.Count(), 'node');
        NodeBank.Get(H, N);
        exit(N);
    end;

    procedure SetNode(H: Integer; N: XmlNode)
    begin
        Guard(H, NodeBank.Count(), 'node');
        NodeBank.Set(H, N);
    end;

    procedure GetList(H: Integer): XmlNodeList
    var
        L: XmlNodeList;
    begin
        Guard(H, ListBank.Count(), 'node list');
        ListBank.Get(H, L);
        exit(L);
    end;

    procedure SetList(H: Integer; L: XmlNodeList)
    begin
        Guard(H, ListBank.Count(), 'node list');
        ListBank.Set(H, L);
    end;

    procedure GetAttrCol(H: Integer): XmlAttributeCollection
    var
        C: XmlAttributeCollection;
    begin
        Guard(H, AttrColBank.Count(), 'attribute collection');
        AttrColBank.Get(H, C);
        exit(C);
    end;

    procedure SetAttrCol(H: Integer; C: XmlAttributeCollection)
    begin
        Guard(H, AttrColBank.Count(), 'attribute collection');
        AttrColBank.Set(H, C);
    end;

    procedure GetNsMgr(H: Integer): XmlNamespaceManager
    var
        M: XmlNamespaceManager;
    begin
        Guard(H, NsMgrBank.Count(), 'namespace manager');
        NsMgrBank.Get(H, M);
        exit(M);
    end;

    procedure SetNsMgr(H: Integer; M: XmlNamespaceManager)
    begin
        Guard(H, NsMgrBank.Count(), 'namespace manager');
        NsMgrBank.Set(H, M);
    end;

    procedure GetReadOpt(H: Integer): XmlReadOptions
    var
        RO: XmlReadOptions;
    begin
        Guard(H, ReadOptBank.Count(), 'read options');
        ReadOptBank.Get(H, RO);
        exit(RO);
    end;

    procedure SetReadOpt(H: Integer; RO: XmlReadOptions)
    begin
        Guard(H, ReadOptBank.Count(), 'read options');
        ReadOptBank.Set(H, RO);
    end;

    procedure GetWriteOpt(H: Integer): XmlWriteOptions
    var
        WO: XmlWriteOptions;
    begin
        Guard(H, WriteOptBank.Count(), 'write options');
        WriteOptBank.Get(H, WO);
        exit(WO);
    end;

    procedure SetWriteOpt(H: Integer; WO: XmlWriteOptions)
    begin
        Guard(H, WriteOptBank.Count(), 'write options');
        WriteOptBank.Set(H, WO);
    end;

    procedure GetNameTable(H: Integer): XmlNameTable
    var
        NT: XmlNameTable;
    begin
        Guard(H, NameTableBank.Count(), 'name table');
        NameTableBank.Get(H, NT);
        exit(NT);
    end;

    procedure SetNameTable(H: Integer; NT: XmlNameTable)
    begin
        Guard(H, NameTableBank.Count(), 'name table');
        NameTableBank.Set(H, NT);
    end;

    // ===== Free (per bank) + kind dispatch — interpreter FreeHandleByKind funnel =====

    procedure FreeNode(H: Integer)
    var
        Blank: XmlNode;
    begin
        if (H < 1) or (H > NodeBank.Count()) then
            exit;
        NodeBank.Set(H, Blank);
        NodeFree.Add(H);
    end;

    procedure FreeList(H: Integer)
    var
        Blank: XmlNodeList;
    begin
        if (H < 1) or (H > ListBank.Count()) then
            exit;
        ListBank.Set(H, Blank);
        ListFree.Add(H);
    end;

    procedure FreeAttrCol(H: Integer)
    var
        Blank: XmlAttributeCollection;
    begin
        if (H < 1) or (H > AttrColBank.Count()) then
            exit;
        AttrColBank.Set(H, Blank);
        AttrColFree.Add(H);
    end;

    procedure FreeNsMgr(H: Integer)
    var
        Blank: XmlNamespaceManager;
    begin
        if (H < 1) or (H > NsMgrBank.Count()) then
            exit;
        NsMgrBank.Set(H, Blank);
        NsMgrFree.Add(H);
    end;

    procedure FreeReadOpt(H: Integer)
    var
        Blank: XmlReadOptions;
    begin
        if (H < 1) or (H > ReadOptBank.Count()) then
            exit;
        ReadOptBank.Set(H, Blank);
        ReadOptFree.Add(H);
    end;

    procedure FreeWriteOpt(H: Integer)
    var
        Blank: XmlWriteOptions;
    begin
        if (H < 1) or (H > WriteOptBank.Count()) then
            exit;
        WriteOptBank.Set(H, Blank);
        WriteOptFree.Add(H);
    end;

    procedure FreeNameTable(H: Integer)
    var
        Blank: XmlNameTable;
    begin
        if (H < 1) or (H > NameTableBank.Count()) then
            exit;
        NameTableBank.Set(H, Blank);
        NameTableFree.Add(H);
    end;

    // One reclaim funnel per TypeKind ordinal — mirrors "ALI Http Runtime".FreeByKind, called
    // from the interpreter's FreeHandleByKind (all 10 node kinds route to the unified NodeBank).
    procedure FreeByKind(Kind: Integer; H: Integer)
    begin
        case Kind of
            "ALI TypeKind"::XmlNodeList:
                FreeList(H);
            "ALI TypeKind"::XmlAttributeCollection:
                FreeAttrCol(H);
            "ALI TypeKind"::XmlNamespaceManager:
                FreeNsMgr(H);
            "ALI TypeKind"::XmlReadOptions:
                FreeReadOpt(H);
            "ALI TypeKind"::XmlWriteOptions:
                FreeWriteOpt(H);
            "ALI TypeKind"::XmlNameTable:
                FreeNameTable(H);
            else
                FreeNode(H);   // the 10 node kinds
        end;
    end;

    // Clear(var X) support (CLEAR_TARGET): reset the handle's slot IN PLACE to a fresh blank of
    // the variable's STATIC kind — mirrors "ALI Json Runtime".ClearJson (other aliases keep the
    // old DOM; native Clear rebinds the cleared variable only).
    procedure ClearXml(H: Integer; TypeOrd: Integer)
    var
        BlankCol: XmlAttributeCollection;
        BlankMgr: XmlNamespaceManager;
        BlankNT: XmlNameTable;
        BlankNode: XmlNode;
        BlankList: XmlNodeList;
        BlankRO: XmlReadOptions;
        BlankWO: XmlWriteOptions;
    begin
        case TypeOrd of
            "ALI TypeKind"::XmlNodeList:
                SetList(H, BlankList);
            "ALI TypeKind"::XmlAttributeCollection:
                SetAttrCol(H, BlankCol);
            "ALI TypeKind"::XmlNamespaceManager:
                SetNsMgr(H, BlankMgr);
            "ALI TypeKind"::XmlReadOptions:
                SetReadOpt(H, BlankRO);
            "ALI TypeKind"::XmlWriteOptions:
                SetWriteOpt(H, BlankWO);
            "ALI TypeKind"::XmlNameTable:
                SetNameTable(H, BlankNT);
            else
                SetNode(H, BlankNode);   // the 10 node kinds
        end;
    end;

    // ===== Per-kind narrowing helpers (native As* Errors on mismatch — that IS the guard) =====

    local procedure GetDoc(H: Integer): XmlDocument
    begin
        exit(GetNode(H).AsXmlDocument());
    end;

    local procedure GetElem(H: Integer): XmlElement
    begin
        exit(GetNode(H).AsXmlElement());
    end;

    local procedure GetAttr(H: Integer): XmlAttribute
    begin
        exit(GetNode(H).AsXmlAttribute());
    end;

    local procedure GetDecl(H: Integer): XmlDeclaration
    begin
        exit(GetNode(H).AsXmlDeclaration());
    end;

    local procedure GetDocType(H: Integer): XmlDocumentType
    begin
        exit(GetNode(H).AsXmlDocumentType());
    end;

    local procedure GetPI(H: Integer): XmlProcessingInstruction
    begin
        exit(GetNode(H).AsXmlProcessingInstruction());
    end;

    // ===== §6 variadic content buffer =====
    // Interpreter calls ContentBegin once, then ContentAddText/ContentAddNode per content arg,
    // then the consuming method proc. Every consumer clears the buffer when done —
    // belt-and-suspenders so a 0-content ElemCreate (id 101) can never see stale entries.

    procedure ContentBegin()
    begin
        Clear(ContentBuf);
    end;

    procedure ContentAddNode(NodeH: Integer)
    begin
        ContentBuf.Add(GetNode(NodeH));
    end;

    procedure ContentAddText(Src: Text)
    begin
        ContentBuf.Add(XmlText.Create(Src).AsXmlNode());   // Text content → XmlText (native coercion)
    end;

    // Append one content node to a container (doc or element, dispatch on actual kind).
    // Attribute content is re-narrowed so the native engine takes its set-attribute path.
    local procedure ContAddOne(N: XmlNode; C: XmlNode)
    var
        XDoc: XmlDocument;
        XElem: XmlElement;
    begin
        if N.IsXmlDocument() then begin
            XDoc := N.AsXmlDocument();
            XDoc.Add(C);   // attributes on a document error natively — mirrors native
            exit;
        end;
        XElem := N.AsXmlElement();
        if C.IsXmlAttribute() then
            XElem.Add(C.AsXmlAttribute())
        else
            XElem.Add(C);
    end;

    local procedure ContAddFirstOne(N: XmlNode; C: XmlNode)
    var
        XDoc: XmlDocument;
        XElem: XmlElement;
    begin
        if N.IsXmlDocument() then begin
            XDoc := N.AsXmlDocument();
            XDoc.AddFirst(C);
            exit;
        end;
        XElem := N.AsXmlElement();
        if C.IsXmlAttribute() then
            XElem.AddFirst(C.AsXmlAttribute())
        else
            XElem.AddFirst(C);
    end;

    // ===== Shared node methods (ids 20-36) — receiver slot is always an XmlNode, and every
    // method here exists on native XmlNode itself, so these are direct passthroughs. =====

    // AddAfterSelf(c1, c2, ...) inserts in argument order: chain the cursor so each content
    // node lands after the previously inserted one (self.AddAfterSelf per item would reverse).
    procedure NodeAddAfterSelf(H: Integer)
    var
        C: XmlNode;
        Cur: XmlNode;
    begin
        Cur := GetNode(H);
        foreach C in ContentBuf do begin
            Cur.AddAfterSelf(C);
            Cur := C;
        end;
        Clear(ContentBuf);
    end;

    // AddBeforeSelf in argument order: each insert lands directly before self — forward loop.
    procedure NodeAddBeforeSelf(H: Integer)
    var
        C: XmlNode;
        N: XmlNode;
    begin
        N := GetNode(H);
        foreach C in ContentBuf do
            N.AddBeforeSelf(C);
        Clear(ContentBuf);
    end;

    procedure NodeAsXmlNode(H: Integer): Integer
    begin
        exit(NewNodeHandle(GetNode(H)));   // id 22: fresh handle, same DOM node, no kind check
    end;

    procedure NodeGetDocument(H: Integer; OutDocH: Integer): Boolean
    var
        XDoc: XmlDocument;
    begin
        if not GetNode(H).GetDocument(XDoc) then
            exit(false);
        SetNode(OutDocH, XDoc.AsXmlNode());
        exit(true);
    end;

    procedure NodeGetParent(H: Integer; OutElemH: Integer): Boolean
    var
        XElem: XmlElement;
    begin
        if not GetNode(H).GetParent(XElem) then
            exit(false);
        SetNode(OutElemH, XElem.AsXmlNode());
        exit(true);
    end;

    procedure NodeRemove(H: Integer)
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        N.Remove();
    end;

    // ReplaceWith(c1, c2, ...): insert content before self in order, then detach self —
    // equivalent to the native variadic (which AL wrappers cannot forward argument-by-argument).
    procedure NodeReplaceWith(H: Integer)
    var
        C: XmlNode;
        N: XmlNode;
    begin
        N := GetNode(H);
        foreach C in ContentBuf do
            N.AddBeforeSelf(C);
        N.Remove();
        Clear(ContentBuf);
    end;

    procedure NodeSelectNodes(H: Integer; XPath: Text; OutListH: Integer): Boolean
    var
        L: XmlNodeList;
    begin
        if not GetNode(H).SelectNodes(XPath, L) then
            exit(false);
        SetList(OutListH, L);
        exit(true);
    end;

    procedure NodeSelectNodesNs(H: Integer; XPath: Text; NsMgrH: Integer; OutListH: Integer): Boolean
    var
        L: XmlNodeList;
    begin
        if not GetNode(H).SelectNodes(XPath, GetNsMgr(NsMgrH), L) then
            exit(false);
        SetList(OutListH, L);
        exit(true);
    end;

    procedure NodeSelectSingle(H: Integer; XPath: Text; OutNodeH: Integer): Boolean
    var
        Found: XmlNode;
    begin
        if not GetNode(H).SelectSingleNode(XPath, Found) then
            exit(false);
        SetNode(OutNodeH, Found);
        exit(true);
    end;

    procedure NodeSelectSingleNs(H: Integer; XPath: Text; NsMgrH: Integer; OutNodeH: Integer): Boolean
    var
        Found: XmlNode;
    begin
        if not GetNode(H).SelectSingleNode(XPath, GetNsMgr(NsMgrH), Found) then
            exit(false);
        SetNode(OutNodeH, Found);
        exit(true);
    end;

    // WriteTo: a document handle serializes the WHOLE doc (incl. declaration) via
    // XmlDocument.WriteTo; any other node serializes its own markup via XmlNode.WriteTo.
    procedure NodeWriteToText(H: Integer; var OutTxt: Text): Boolean
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(N.AsXmlDocument().WriteTo(OutTxt));
        exit(N.WriteTo(OutTxt));
    end;

    procedure NodeWriteToTextOpt(H: Integer; WriteOptH: Integer; var OutTxt: Text): Boolean
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(N.AsXmlDocument().WriteTo(GetWriteOpt(WriteOptH), OutTxt));
        exit(N.WriteTo(GetWriteOpt(WriteOptH), OutTxt));
    end;

    procedure NodeWriteToStream(H: Integer; var OutS: OutStream): Boolean
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(N.AsXmlDocument().WriteTo(OutS));
        exit(N.WriteTo(OutS));
    end;

    procedure NodeWriteToStreamOpt(H: Integer; WriteOptH: Integer; var OutS: OutStream): Boolean
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(N.AsXmlDocument().WriteTo(GetWriteOpt(WriteOptH), OutS));
        exit(N.WriteTo(GetWriteOpt(WriteOptH), OutS));
    end;

    // Value getter/setter — binder gates receivers to attr/comment/cdata/text/pi; dispatch on
    // the ACTUAL stored kind (last arm's native As* raises the kind-mismatch error otherwise).
    procedure NodeValueGet(H: Integer): Text
    var
        V: Text;
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlAttribute() then
            exit(N.AsXmlAttribute().Value());
        if N.IsXmlComment() then
            exit(N.AsXmlComment().Value());
        if N.IsXmlCData() then
            exit(N.AsXmlCData().Value());
        if N.IsXmlText() then
            exit(N.AsXmlText().Value());
        // PI: native alc has NO Value() (docs claim one) — its value IS the data (GetData).
        if N.AsXmlProcessingInstruction().GetData(V) then
            exit(V);
        exit('');
    end;

    procedure NodeValueSet(H: Integer; V: Text)
    var
        XAttr: XmlAttribute;
        XCd: XmlCData;
        XCom: XmlComment;
        N: XmlNode;
        XPi: XmlProcessingInstruction;
        XTxt: XmlText;
    begin
        N := GetNode(H);
        if N.IsXmlAttribute() then begin
            XAttr := N.AsXmlAttribute();
            XAttr.Value(V);
            exit;
        end;
        if N.IsXmlComment() then begin
            XCom := N.AsXmlComment();
            XCom.Value(V);
            exit;
        end;
        if N.IsXmlCData() then begin
            XCd := N.AsXmlCData();
            XCd.Value(V);
            exit;
        end;
        if N.IsXmlText() then begin
            XTxt := N.AsXmlText();
            XTxt.Value(V);
            exit;
        end;
        XPi := N.AsXmlProcessingInstruction();
        XPi.SetData(V);   // PI Value setter = SetData (no native Value, see NodeValueGet)
    end;

    // Is* (ids 77-85): KindOrd = ALI TypeKind ordinal of the probed kind.
    procedure NodeIsKind(H: Integer; KindOrd: Integer): Boolean
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        case KindOrd of
            "ALI TypeKind"::XmlDocument:
                exit(N.IsXmlDocument());
            "ALI TypeKind"::XmlElement:
                exit(N.IsXmlElement());
            "ALI TypeKind"::XmlAttribute:
                exit(N.IsXmlAttribute());
            "ALI TypeKind"::XmlComment:
                exit(N.IsXmlComment());
            "ALI TypeKind"::XmlCData:
                exit(N.IsXmlCData());
            "ALI TypeKind"::XmlDeclaration:
                exit(N.IsXmlDeclaration());
            "ALI TypeKind"::XmlDocumentType:
                exit(N.IsXmlDocumentType());
            "ALI TypeKind"::XmlText:
                exit(N.IsXmlText());
            "ALI TypeKind"::XmlProcessingInstruction:
                exit(N.IsXmlProcessingInstruction());
            else
                Error('ALI976: unknown Xml kind ordinal %1', KindOrd);
        end;
    end;

    // As* (ids 68-76): narrow to force the NATIVE kind-mismatch error, then hand out a fresh
    // handle aliasing the same DOM node (handle-returning alloc rule, §7).
    procedure NodeAsKind(H: Integer; KindOrd: Integer): Integer
    var
        XAttr: XmlAttribute;
        XCd: XmlCData;
        XCom: XmlComment;
        XDecl: XmlDeclaration;
        XDoc: XmlDocument;
        XDt: XmlDocumentType;
        XElem: XmlElement;
        N: XmlNode;
        XPi: XmlProcessingInstruction;
        XTxt: XmlText;
    begin
        N := GetNode(H);
        case KindOrd of
            "ALI TypeKind"::XmlDocument:
                XDoc := N.AsXmlDocument();
            "ALI TypeKind"::XmlElement:
                XElem := N.AsXmlElement();
            "ALI TypeKind"::XmlAttribute:
                XAttr := N.AsXmlAttribute();
            "ALI TypeKind"::XmlComment:
                XCom := N.AsXmlComment();
            "ALI TypeKind"::XmlCData:
                XCd := N.AsXmlCData();
            "ALI TypeKind"::XmlDeclaration:
                XDecl := N.AsXmlDeclaration();
            "ALI TypeKind"::XmlDocumentType:
                XDt := N.AsXmlDocumentType();
            "ALI TypeKind"::XmlText:
                XTxt := N.AsXmlText();
            "ALI TypeKind"::XmlProcessingInstruction:
                XPi := N.AsXmlProcessingInstruction();
            else
                Error('ALI976: unknown Xml kind ordinal %1', KindOrd);
        end;
        exit(NewNodeHandle(N));
    end;

    // ===== Container methods (ids 40-51) — receiver is a doc OR element; both native types
    // carry the identical method surface, dispatch on the actual stored kind. =====

    procedure ContAdd(H: Integer)
    var
        C: XmlNode;
        N: XmlNode;
    begin
        N := GetNode(H);
        foreach C in ContentBuf do
            ContAddOne(N, C);
        Clear(ContentBuf);
    end;

    // AddFirst(c1, c2, ...) keeps argument order at the front — insert back-to-front.
    procedure ContAddFirst(H: Integer)
    var
        i: Integer;
        C: XmlNode;
        N: XmlNode;
    begin
        N := GetNode(H);
        for i := ContentBuf.Count() downto 1 do begin
            C := ContentBuf.Get(i);
            ContAddFirstOne(N, C);
        end;
        Clear(ContentBuf);
    end;

    // ReplaceNodes = RemoveNodes (children only, attributes survive — native semantics) + Add.
    procedure ContReplaceNodes(H: Integer)
    var
        C: XmlNode;
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            N.AsXmlDocument().RemoveNodes()
        else
            N.AsXmlElement().RemoveNodes();
        foreach C in ContentBuf do
            ContAddOne(N, C);
        Clear(ContentBuf);
    end;

    procedure ContChildElements(H: Integer): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetChildElements()));
        exit(NewListHandle(N.AsXmlElement().GetChildElements()));
    end;

    procedure ContChildElementsName(H: Integer; LocalName: Text): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetChildElements(LocalName)));
        exit(NewListHandle(N.AsXmlElement().GetChildElements(LocalName)));
    end;

    procedure ContChildElementsNs(H: Integer; NsUri: Text; LocalName: Text): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetChildElements(NsUri, LocalName)));
        exit(NewListHandle(N.AsXmlElement().GetChildElements(NsUri, LocalName)));
    end;

    procedure ContChildNodes(H: Integer): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetChildNodes()));
        exit(NewListHandle(N.AsXmlElement().GetChildNodes()));
    end;

    procedure ContDescendantElements(H: Integer): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetDescendantElements()));
        exit(NewListHandle(N.AsXmlElement().GetDescendantElements()));
    end;

    procedure ContDescendantElementsName(H: Integer; LocalName: Text): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetDescendantElements(LocalName)));
        exit(NewListHandle(N.AsXmlElement().GetDescendantElements(LocalName)));
    end;

    procedure ContDescendantElementsNs(H: Integer; NsUri: Text; LocalName: Text): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetDescendantElements(NsUri, LocalName)));
        exit(NewListHandle(N.AsXmlElement().GetDescendantElements(NsUri, LocalName)));
    end;

    procedure ContDescendantNodes(H: Integer): Integer
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            exit(NewListHandle(N.AsXmlDocument().GetDescendantNodes()));
        exit(NewListHandle(N.AsXmlElement().GetDescendantNodes()));
    end;

    procedure ContRemoveNodes(H: Integer)
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlDocument() then
            N.AsXmlDocument().RemoveNodes()
        else
            N.AsXmlElement().RemoveNodes();
    end;

    // ===== XmlDocument (ids 55-65) =====

    procedure DocGetDeclaration(H: Integer; OutDeclH: Integer): Boolean
    var
        XDecl: XmlDeclaration;
    begin
        if not GetDoc(H).GetDeclaration(XDecl) then
            exit(false);
        SetNode(OutDeclH, XDecl.AsXmlNode());
        exit(true);
    end;

    procedure DocGetDocumentType(H: Integer; OutDtH: Integer): Boolean
    var
        XDt: XmlDocumentType;
    begin
        if not GetDoc(H).GetDocumentType(XDt) then
            exit(false);
        SetNode(OutDtH, XDt.AsXmlNode());
        exit(true);
    end;

    procedure DocGetRoot(H: Integer; OutElemH: Integer): Boolean
    var
        XElem: XmlElement;
    begin
        if not GetDoc(H).GetRoot(XElem) then
            exit(false);
        SetNode(OutElemH, XElem.AsXmlNode());
        exit(true);
    end;

    procedure DocNameTable(H: Integer): Integer
    begin
        exit(NewNameTableHandle(GetDoc(H).NameTable()));
    end;

    procedure DocSetDeclaration(H: Integer; DeclH: Integer)
    var
        XDoc: XmlDocument;
    begin
        XDoc := GetDoc(H);
        XDoc.SetDeclaration(GetDecl(DeclH));
    end;

    procedure DocCreate(): Integer
    begin
        exit(NewNodeHandle(XmlDocument.Create().AsXmlNode()));
    end;

    // Create(Any,...): declaration content is routed to SetDeclaration — the native variadic
    // Create accepts a declaration as content but Add would reject it (XDocument ctor rule).
    procedure DocCreateWithContent(): Integer
    var
        XDoc: XmlDocument;
        C: XmlNode;
    begin
        XDoc := XmlDocument.Create();
        foreach C in ContentBuf do
            if C.IsXmlDeclaration() then
                XDoc.SetDeclaration(C.AsXmlDeclaration())
            else
                XDoc.Add(C);
        Clear(ContentBuf);
        exit(NewNodeHandle(XDoc.AsXmlNode()));
    end;

    procedure DocReadFromText(Src: Text; OutDocH: Integer): Boolean
    var
        Ok: Boolean;
        XDoc: XmlDocument;
    begin
        Ok := XmlDocument.ReadFrom(Src, XDoc);
        SetNode(OutDocH, XDoc.AsXmlNode());   // rebind even on failure (native leaves blank doc)
        exit(Ok);
    end;

    procedure DocReadFromTextOpt(Src: Text; ReadOptH: Integer; OutDocH: Integer): Boolean
    var
        Ok: Boolean;
        XDoc: XmlDocument;
    begin
        Ok := XmlDocument.ReadFrom(Src, GetReadOpt(ReadOptH), XDoc);
        SetNode(OutDocH, XDoc.AsXmlNode());
        exit(Ok);
    end;

    procedure DocReadFromStream(var InS: InStream; OutDocH: Integer): Boolean
    var
        Ok: Boolean;
        XDoc: XmlDocument;
    begin
        Ok := XmlDocument.ReadFrom(InS, XDoc);
        SetNode(OutDocH, XDoc.AsXmlNode());
        exit(Ok);
    end;

    procedure DocReadFromStreamOpt(var InS: InStream; ReadOptH: Integer; OutDocH: Integer): Boolean
    var
        Ok: Boolean;
        XDoc: XmlDocument;
    begin
        Ok := XmlDocument.ReadFrom(InS, GetReadOpt(ReadOptH), XDoc);
        SetNode(OutDocH, XDoc.AsXmlNode());
        exit(Ok);
    end;

    // ===== Name/content getters (ids 90-98) — 90-92 legal on element AND attribute =====

    procedure NodeLocalName(H: Integer): Text
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlAttribute() then
            exit(N.AsXmlAttribute().LocalName());
        exit(N.AsXmlElement().LocalName());
    end;

    procedure NodeName(H: Integer): Text
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlAttribute() then
            exit(N.AsXmlAttribute().Name());
        exit(N.AsXmlElement().Name());
    end;

    procedure NodeNamespaceUri(H: Integer): Text
    var
        N: XmlNode;
    begin
        N := GetNode(H);
        if N.IsXmlAttribute() then
            exit(N.AsXmlAttribute().NamespaceUri());
        exit(N.AsXmlElement().NamespaceUri());
    end;

    procedure ElemInnerText(H: Integer): Text
    begin
        exit(GetElem(H).InnerText());
    end;

    procedure ElemInnerXml(H: Integer): Text
    begin
        exit(GetElem(H).InnerXml());
    end;

    procedure ElemHasAttributes(H: Integer): Boolean
    begin
        exit(GetElem(H).HasAttributes());
    end;

    procedure ElemHasElements(H: Integer): Boolean
    begin
        exit(GetElem(H).HasElements());
    end;

    procedure ElemIsEmpty(H: Integer): Boolean
    begin
        exit(GetElem(H).IsEmpty());
    end;

    procedure ElemAttributes(H: Integer): Integer
    begin
        exit(NewAttrColHandle(GetElem(H).Attributes()));
    end;

    // ===== XmlElement statics + instance (ids 101-113) =====

    // Create(localName [, content...]) — ids 101/104; buffer may be empty.
    procedure ElemCreate(LocalName: Text): Integer
    var
        XElem: XmlElement;
        C: XmlNode;
    begin
        XElem := XmlElement.Create(LocalName);
        foreach C in ContentBuf do
            ContAddOne(XElem.AsXmlNode(), C);
        Clear(ContentBuf);
        exit(NewNodeHandle(XElem.AsXmlNode()));
    end;

    // Create(localName, namespaceUri [, content...]) — ids 102/103.
    procedure ElemCreateNs(LocalName: Text; NsUri: Text): Integer
    var
        XElem: XmlElement;
        C: XmlNode;
    begin
        XElem := XmlElement.Create(LocalName, NsUri);
        foreach C in ContentBuf do
            ContAddOne(XElem.AsXmlNode(), C);
        Clear(ContentBuf);
        exit(NewNodeHandle(XElem.AsXmlNode()));
    end;

    procedure ElemGetNsOfPrefix(H: Integer; Prefix: Text; var OutNs: Text): Boolean
    begin
        exit(GetElem(H).GetNamespaceOfPrefix(Prefix, OutNs));
    end;

    procedure ElemGetPrefixOfNs(H: Integer; NsUri: Text; var OutPrefix: Text): Boolean
    begin
        exit(GetElem(H).GetPrefixOfNamespace(NsUri, OutPrefix));
    end;

    procedure ElemRemoveAllAttributes(H: Integer)
    var
        XElem: XmlElement;
    begin
        XElem := GetElem(H);
        XElem.RemoveAllAttributes();
    end;

    procedure ElemRemoveAttribute(H: Integer; LocalName: Text)
    var
        XElem: XmlElement;
    begin
        XElem := GetElem(H);
        XElem.RemoveAttribute(LocalName);
    end;

    procedure ElemRemoveAttributeNs(H: Integer; LocalName: Text; NsUri: Text)
    var
        XElem: XmlElement;
    begin
        XElem := GetElem(H);
        XElem.RemoveAttribute(LocalName, NsUri);
    end;

    procedure ElemRemoveAttributeByAttr(H: Integer; AttrH: Integer)
    var
        XElem: XmlElement;
    begin
        XElem := GetElem(H);
        XElem.RemoveAttribute(GetAttr(AttrH));
    end;

    procedure ElemSetAttribute(H: Integer; AttrName: Text; Value: Text)
    var
        XElem: XmlElement;
    begin
        XElem := GetElem(H);
        XElem.SetAttribute(AttrName, Value);
    end;

    procedure ElemSetAttributeNs(H: Integer; AttrName: Text; NsUri: Text; Value: Text)
    var
        XElem: XmlElement;
    begin
        XElem := GetElem(H);
        XElem.SetAttribute(AttrName, NsUri, Value);
    end;

    // ===== XmlAttribute (ids 116-120) =====

    procedure AttrCreate(AttrName: Text; Value: Text): Integer
    begin
        exit(NewNodeHandle(XmlAttribute.Create(AttrName, Value).AsXmlNode()));
    end;

    procedure AttrCreateNs(AttrName: Text; NsUri: Text; Value: Text): Integer
    begin
        exit(NewNodeHandle(XmlAttribute.Create(AttrName, NsUri, Value).AsXmlNode()));
    end;

    procedure AttrCreateNsDecl(Prefix: Text; NsUri: Text): Integer
    begin
        exit(NewNodeHandle(XmlAttribute.CreateNamespaceDeclaration(Prefix, NsUri).AsXmlNode()));
    end;

    procedure AttrIsNsDeclaration(H: Integer): Boolean
    begin
        exit(GetAttr(H).IsNamespaceDeclaration());
    end;

    procedure AttrNamespacePrefix(H: Integer): Text
    begin
        exit(GetAttr(H).NamespacePrefix());
    end;

    // ===== XmlNodeList (ids 123-124; native 1-BASED) + foreach Get =====

    procedure NodeListCount(H: Integer): Integer
    begin
        exit(GetList(H).Count());
    end;

    procedure NodeListGet(H: Integer; Idx: Integer; OutNodeH: Integer): Boolean
    var
        N: XmlNode;
    begin
        if not GetList(H).Get(Idx, N) then
            exit(false);
        SetNode(OutNodeH, N);
        exit(true);
    end;

    // ===== XmlAttributeCollection (ids 127-136; 1-based) + foreach Get =====

    procedure AttrColCount(H: Integer): Integer
    begin
        exit(GetAttrCol(H).Count());
    end;

    procedure AttrColGetIdx(H: Integer; Idx: Integer; OutAttrH: Integer): Boolean
    var
        XAttr: XmlAttribute;
    begin
        if not GetAttrCol(H).Get(Idx, XAttr) then
            exit(false);
        SetNode(OutAttrH, XAttr.AsXmlNode());
        exit(true);
    end;

    procedure AttrColGetName(H: Integer; LocalName: Text; OutAttrH: Integer): Boolean
    var
        XAttr: XmlAttribute;
    begin
        if not GetAttrCol(H).Get(LocalName, XAttr) then
            exit(false);
        SetNode(OutAttrH, XAttr.AsXmlNode());
        exit(true);
    end;

    procedure AttrColGetNs(H: Integer; LocalName: Text; NsUri: Text; OutAttrH: Integer): Boolean
    var
        XAttr: XmlAttribute;
    begin
        if not GetAttrCol(H).Get(LocalName, NsUri, XAttr) then
            exit(false);
        SetNode(OutAttrH, XAttr.AsXmlNode());
        exit(true);
    end;

    procedure AttrColRemoveAttr(H: Integer; AttrH: Integer)
    var
        C: XmlAttributeCollection;
    begin
        C := GetAttrCol(H);
        C.Remove(GetAttr(AttrH));
        SetAttrCol(H, C);
    end;

    procedure AttrColRemoveName(H: Integer; LocalName: Text)
    var
        C: XmlAttributeCollection;
    begin
        C := GetAttrCol(H);
        C.Remove(LocalName);
        SetAttrCol(H, C);
    end;

    procedure AttrColRemoveNs(H: Integer; LocalName: Text; NsUri: Text)
    var
        C: XmlAttributeCollection;
    begin
        C := GetAttrCol(H);
        C.Remove(LocalName, NsUri);
        SetAttrCol(H, C);
    end;

    procedure AttrColRemoveAll(H: Integer)
    var
        C: XmlAttributeCollection;
    begin
        C := GetAttrCol(H);
        C.RemoveAll();
        SetAttrCol(H, C);
    end;

    procedure AttrColSet(H: Integer; AttrName: Text; Value: Text)
    var
        C: XmlAttributeCollection;
    begin
        C := GetAttrCol(H);
        C.Set(AttrName, Value);
        SetAttrCol(H, C);
    end;

    procedure AttrColSetNs(H: Integer; AttrName: Text; NsUri: Text; Value: Text)
    var
        C: XmlAttributeCollection;
    begin
        C := GetAttrCol(H);
        C.Set(AttrName, NsUri, Value);
        SetAttrCol(H, C);
    end;

    // ===== Simple-node statics (ids 140-148) =====

    procedure CommentCreate(V: Text): Integer
    begin
        exit(NewNodeHandle(XmlComment.Create(V).AsXmlNode()));
    end;

    procedure CDataCreate(V: Text): Integer
    begin
        exit(NewNodeHandle(XmlCData.Create(V).AsXmlNode()));
    end;

    procedure TextCreate(V: Text): Integer
    begin
        exit(NewNodeHandle(XmlText.Create(V).AsXmlNode()));
    end;

    procedure PICreate(PITarget: Text; Data: Text): Integer
    begin
        exit(NewNodeHandle(XmlProcessingInstruction.Create(PITarget, Data).AsXmlNode()));
    end;

    procedure DeclCreate(Ver: Text; Enc: Text; Standalone: Text): Integer
    begin
        exit(NewNodeHandle(XmlDeclaration.Create(Ver, Enc, Standalone).AsXmlNode()));
    end;

    procedure DocTypeCreate1(DtName: Text): Integer
    begin
        exit(NewNodeHandle(XmlDocumentType.Create(DtName).AsXmlNode()));
    end;

    procedure DocTypeCreate2(DtName: Text; PublicId: Text): Integer
    begin
        exit(NewNodeHandle(XmlDocumentType.Create(DtName, PublicId).AsXmlNode()));
    end;

    procedure DocTypeCreate3(DtName: Text; PublicId: Text; SystemId: Text): Integer
    begin
        exit(NewNodeHandle(XmlDocumentType.Create(DtName, PublicId, SystemId).AsXmlNode()));
    end;

    procedure DocTypeCreate4(DtName: Text; PublicId: Text; SystemId: Text; Subset: Text): Integer
    begin
        exit(NewNodeHandle(XmlDocumentType.Create(DtName, PublicId, SystemId, Subset).AsXmlNode()));
    end;

    // ===== XmlDeclaration (ids 150-155) =====

    procedure DeclEncodingGet(H: Integer): Text
    begin
        exit(GetDecl(H).Encoding());
    end;

    procedure DeclEncodingSet(H: Integer; V: Text)
    var
        XDecl: XmlDeclaration;
    begin
        XDecl := GetDecl(H);
        XDecl.Encoding(V);
    end;

    procedure DeclStandaloneGet(H: Integer): Text
    begin
        exit(GetDecl(H).Standalone());
    end;

    procedure DeclStandaloneSet(H: Integer; V: Text)
    var
        XDecl: XmlDeclaration;
    begin
        XDecl := GetDecl(H);
        XDecl.Standalone(V);
    end;

    procedure DeclVersionGet(H: Integer): Text
    begin
        exit(GetDecl(H).Version());
    end;

    procedure DeclVersionSet(H: Integer; V: Text)
    var
        XDecl: XmlDeclaration;
    begin
        XDecl := GetDecl(H);
        XDecl.Version(V);
    end;

    // ===== XmlDocumentType (ids 158-165) =====

    procedure DocTypeGetInternalSubset(H: Integer; var OutV: Text): Boolean
    begin
        exit(GetDocType(H).GetInternalSubset(OutV));
    end;

    procedure DocTypeGetName(H: Integer; var OutV: Text): Boolean
    begin
        exit(GetDocType(H).GetName(OutV));
    end;

    procedure DocTypeGetPublicId(H: Integer; var OutV: Text): Boolean
    begin
        exit(GetDocType(H).GetPublicId(OutV));
    end;

    procedure DocTypeGetSystemId(H: Integer; var OutV: Text): Boolean
    begin
        exit(GetDocType(H).GetSystemId(OutV));
    end;

    procedure DocTypeSetInternalSubset(H: Integer; V: Text)
    var
        XDt: XmlDocumentType;
    begin
        XDt := GetDocType(H);
        XDt.SetInternalSubset(V);
    end;

    procedure DocTypeSetName(H: Integer; V: Text)
    var
        XDt: XmlDocumentType;
    begin
        XDt := GetDocType(H);
        XDt.SetName(V);
    end;

    procedure DocTypeSetPublicId(H: Integer; V: Text)
    var
        XDt: XmlDocumentType;
    begin
        XDt := GetDocType(H);
        XDt.SetPublicId(V);
    end;

    procedure DocTypeSetSystemId(H: Integer; V: Text)
    var
        XDt: XmlDocumentType;
    begin
        XDt := GetDocType(H);
        XDt.SetSystemId(V);
    end;

    // ===== XmlProcessingInstruction (id 168) =====

    // Native alc exposes GetTarget(var Text): Boolean, not Target(): Text (docs claim the
    // latter — XML_SPEC shape kept for users; false ⇒ empty Text).
    procedure PITargetGet(H: Integer): Text
    var
        V: Text;
    begin
        if GetPI(H).GetTarget(V) then
            exit(V);
        exit('');
    end;

    // ===== XmlNamespaceManager (ids 171-179) — value-copy write-back after every mutator =====

    procedure NsMgrAddNamespace(H: Integer; Prefix: Text; NsUri: Text)
    var
        M: XmlNamespaceManager;
    begin
        M := GetNsMgr(H);
        M.AddNamespace(Prefix, NsUri);
        SetNsMgr(H, M);
    end;

    procedure NsMgrHasNamespace(H: Integer; Prefix: Text): Boolean
    begin
        exit(GetNsMgr(H).HasNamespace(Prefix));
    end;

    procedure NsMgrLookupNamespace(H: Integer; Prefix: Text; var OutNs: Text): Boolean
    begin
        exit(GetNsMgr(H).LookupNamespace(Prefix, OutNs));
    end;

    procedure NsMgrLookupPrefix(H: Integer; NsUri: Text; var OutPrefix: Text): Boolean
    begin
        exit(GetNsMgr(H).LookupPrefix(NsUri, OutPrefix));
    end;

    procedure NsMgrNameTableGet(H: Integer): Integer
    begin
        exit(NewNameTableHandle(GetNsMgr(H).NameTable()));
    end;

    procedure NsMgrNameTableSet(H: Integer; NameTableH: Integer)
    var
        M: XmlNamespaceManager;
    begin
        M := GetNsMgr(H);
        M.NameTable(GetNameTable(NameTableH));
        SetNsMgr(H, M);
    end;

    // Native alc PopScope/RemoveNamespace return VOID (docs claim Boolean); the ALI surface
    // keeps the documented Boolean — constant true (no native signal to forward).
    procedure NsMgrPopScope(H: Integer): Boolean
    var
        M: XmlNamespaceManager;
    begin
        M := GetNsMgr(H);
        M.PopScope();
        SetNsMgr(H, M);
        exit(true);
    end;

    procedure NsMgrPushScope(H: Integer)
    var
        M: XmlNamespaceManager;
    begin
        M := GetNsMgr(H);
        M.PushScope();
        SetNsMgr(H, M);
    end;

    procedure NsMgrRemoveNamespace(H: Integer; Prefix: Text; NsUri: Text): Boolean
    var
        M: XmlNamespaceManager;
    begin
        M := GetNsMgr(H);
        M.RemoveNamespace(Prefix, NsUri);
        SetNsMgr(H, M);
        exit(true);   // native returns void — see PopScope note
    end;

    // ===== Xml{Read,Write}Options (ids 182-185) — value-mutate + Set back (§8) =====

    procedure ReadOptPreserveWsGet(H: Integer): Boolean
    begin
        exit(GetReadOpt(H).PreserveWhitespace());
    end;

    procedure ReadOptPreserveWsSet(H: Integer; V: Boolean)
    var
        RO: XmlReadOptions;
    begin
        RO := GetReadOpt(H);
        RO.PreserveWhitespace(V);
        SetReadOpt(H, RO);
    end;

    procedure WriteOptPreserveWsGet(H: Integer): Boolean
    begin
        exit(GetWriteOpt(H).PreserveWhitespace());
    end;

    procedure WriteOptPreserveWsSet(H: Integer; V: Boolean)
    var
        WO: XmlWriteOptions;
    begin
        WO := GetWriteOpt(H);
        WO.PreserveWhitespace(V);
        SetWriteOpt(H, WO);
    end;
}
