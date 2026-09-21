page 51103 "ALI Stored Scripts"
{
    ApplicationArea = All;
    Caption = 'AL Stored Scripts';
    CardPageId = "ALI Script Editor";
    PageType = List;
    SourceTable = "ALI Stored Script";
    Editable = false;

    layout
    {
        area(Content)
        {
            repeater(Group)
            {
                field(Name; Rec.Name)
                {
                    NotBlank = true;
                    ShowMandatory = true;
                    ToolTip = 'Specifies the name the script is stored and reopened under.', Comment = 'Spécifie le nom sous lequel le script est enregistré et rouvert.';
                }
                field(Description; Rec.Description)
                {
                    ToolTip = 'Specifies what this script does, shown only in this list.', Comment = 'Spécifie ce que fait ce script, affiché uniquement dans cette liste.';
                }
                field(SystemCreatedAt; Rec.SystemCreatedAt)
                {
                    Editable = false;
                    ToolTip = 'Specifies when the script was first saved.', Comment = 'Spécifie la date de premier enregistrement du script.';
                }
                field(SystemModifiedAt; Rec.SystemModifiedAt)
                {
                    Editable = false;
                    ToolTip = 'Specifies when the script was last saved.', Comment = 'Spécifie la date du dernier enregistrement du script.';
                }
            }
        }
    }
}