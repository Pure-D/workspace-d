module workspaced.coms;

import std.meta;

public import workspaced.com.dcd : DCDComponent;
public import workspaced.com.dfmt : DfmtComponent;
public import workspaced.com.dlangui : DlanguiComponent;
public import workspaced.com.dscanner : DscannerComponent;
public import workspaced.com.dub : DubComponent;
public import workspaced.com.fsworkspace : FSWorkspaceComponent;
public import workspaced.com.importer : ImporterComponent;
public import workspaced.com.moduleman : ModulemanComponent;
public import workspaced.com.dcdext : DCDExtComponent;
public import workspaced.com.dmd : DMDComponent;

alias AllComponents = AliasSeq!(DCDComponent, DfmtComponent, DlanguiComponent, DscannerComponent, DubComponent,
		FSWorkspaceComponent, ImporterComponent, ModulemanComponent, DCDExtComponent, DMDComponent);
