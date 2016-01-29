module workspaced.com.dlangui;

import std.json;
import std.process;
import std.algorithm;
import std.string;
import std.uni;
import core.thread;

import painlessjson;

import workspaced.api;

@component("dlangui") :

@load void start()
{
}

@unload void stop()
{
}

/// Queries for code completion at position `pos` in DML code
/// Returns: `[{type: CompletionType, value: string}]`
/// Where type is an integer
/// Call_With: `{"subcmd": "list-completion"}`
@arguments("subcmd", "list-completion")
@async void complete(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			LocationInfo info = getLocationInfo(code, pos);
			CompletionItem[] suggestions;
			final switch (info.type) with (LocationType)
			{
			case RootMember:
				if (info.name.length == 0)
				{
					foreach (widget; widgets)
					{
						suggestions ~= CompletionItem(CompletionType.Class, widget);
					}
				}
				else
				{
					foreach (widget; widgets)
					{
						if (widget.toUpper.canFind(info.name.toUpper))
						{
							suggestions ~= CompletionItem(CompletionType.Class, widget);
						}
					}
				}
				break;
			case Member:
				if (info.name.length == 0)
				{
					foreach (prop; baseProperties)
					{
						suggestions ~= CompletionItem(CompletionType.Property, prop);
					}
					foreach (widget; widgets)
					{
						suggestions ~= CompletionItem(CompletionType.Class, widget);
					}
				}
				else
				{
					foreach (property; baseProperties)
					{
						if (property.toUpper.canFind(info.name.toUpper))
						{
							suggestions ~= CompletionItem(CompletionType.Property, property);
						}
					}
					foreach (widget; widgets)
					{
						if (widget.toUpper.canFind(info.name.toUpper))
						{
							suggestions ~= CompletionItem(CompletionType.Class, widget);
						}
					}
				}
				break;
			case PropertyValue:
				// TODO: Add possible enums/values
				break;
			case None:
				break;
			}
			cb(null, suggestions.toJSON);
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

///
enum CompletionType
{
	///
	Class = 1,
	///
	Property = 2
}

__gshared private:

struct CompletionItem
{
	CompletionType type;
	string value;
}

enum LocationType
{
	RootMember,
	Member,
	PropertyValue,
	None
}

struct LocationInfo
{
	LocationType type;
	string name;
}

LocationInfo getLocationInfo(in string code, int pos)
{
	LocationInfo current;
	current.type = LocationType.RootMember;
	current.name = "";
	bool inString = false;
	bool escapeChar = false;
	foreach (i, c; code)
	{
		if (i == pos)
			return current;
		if (inString)
		{
			if (escapeChar)
				escapeChar = false;
			else
			{
				if (c == '\\')
				{
					escapeChar = true;
				}
				else if (c == '"')
				{
					inString = false;
					current.name = "";
					current.type = LocationType.None;
					escapeChar = false;
				}
			}
			continue;
		}
		else
		{
			if (c == '{' || c == '\n' || c == '\r' || c == ';')
			{
				current.name = "";
				current.type = LocationType.Member;
			}
			else if (c == ':')
			{
				current.name = "";
				current.type = LocationType.PropertyValue;
			}
			else if (c == '"')
			{
				inString = true;
			}
			else if (c == '}')
			{
				if (current.type == LocationType.PropertyValue)
					current.type = LocationType.None;
			}
			else if (c.isWhite)
			{
				current.name = "";
			}
			else
			{
				if (current.type == LocationType.Member || current.type == LocationType.RootMember)
					current.name ~= c;
			}
		}
	}
	return current;
}

unittest
{
	auto info = getLocationInfo("", 0);
	assert(info.type == LocationType.RootMember);
	info = getLocationInfo(`TableLayout { mar }`, 17);
	assert(info.type == LocationType.Member);
	assert(info.name == "mar");
	info = getLocationInfo(`TableLayout { margins: 20; paddin }`, 33);
	assert(info.type == LocationType.Member);
	assert(info.name == "paddin");
	info = getLocationInfo("TableLayout { margins: 20; padding : 10\n\t\tTextWidget { text: \"} foo } }", 70);
	assert(info.type == LocationType.PropertyValue);
	info = getLocationInfo(`TableLayout { margins: 2 }`, 24);
	assert(info.type == LocationType.PropertyValue);
	info = getLocationInfo("TableLayout { margins: 20; padding : 10\n\t\tTextWidget { text: \"} foobar\" } }", 74);
	assert(info.type == LocationType.None);
	info = getLocationInfo("TableLayout { margins: 20; padding : 10\n\t\tTextWidget { text: \"} foobar\"; } }", 75);
	assert(info.type == LocationType.Member);
	info = getLocationInfo("TableLayout {\n\t", 17);
	assert(info.type == LocationType.Member);
	assert(info.name == "", info.name);
	info = getLocationInfo(`TableLayout {
	colCount: 2
	margins: 20; padding: 10
	backgroundColor: "#FFFFE0"
	TextWidget {
		t`, int.max);
	assert(info.type == LocationType.Member);
	assert(info.name == "t");
}

//dfmt off
static immutable string[] widgets = [
	// appframe
	"AppFrame",
	// combobox
	"ComboBox",
	"ComboBoxBase",
	"ComboEdit",
	// controls
	"AbstractSlider",
	"Button",
	"CheckBox",
	"HSpacer",
	"ImageButton",
	"ImageTextButton",
	"ImageWidget",
	"RadioButton",
	"ScrollBar",
	"TextWidget",
	"VSpacer",
	// docks
	"DockHost",
	"DockWindow",
	// editors
	"EditBox",
	"EditLine",
	"EditOperation",
	"EditWidgetBase",
	"UndoBuffer",
	// grid
	"GridWidgetBase",
	"StringGridAdapter",
	"StringGridWidget",
	"StringGridWidgetBase",
	// layouts
	"FrameLayout",
	"HorizontalLayout",
	"LinearLayout",
	"ResizerWidget",
	"TableLayout",
	"VerticalLayout",
	// lists
	"ListWidget",
	"StringListAdapter",
	"WidgetListAdapter",
	// menu
	"MainMenu",
	"MenuItemWidget",
	"MenuWidgetBase",
	"PopupMenu",
	// popup
	"PopupWidget",
	// scroll
	"ScrollWidget",
	"ScrollWidgetBase",
	// srcedit
	"SourceEdit",
	// statusline
	"StatusLine",
	// styles
	// tabs
	"TabControl",
	"TabHost",
	"TabItemWidget",
	"TabWidget",
	// toolbars
	"ToolBar",
	"ToolBarHost",
	"ToolBarImageButton",
	"ToolBarSeparator",
	// tree
	"TreeItemWidget",
	"TreeWidget",
	"TreeWidgetBase",
	// widget
	"Widget",
	"WidgetGroup",
	"WidgetGroupDefaultDrawing",
];

static immutable string[] baseProperties = [
	"action",
	"alignment",
	"alpha",
	"backgroundColor",
	"backgroundImageId",
	"checkable",
	"checked",
	"clickable",
	"enabled",
	"focusable",
	"focusGroup",
	"fontFace",
	"fontFamily",
	"fontItalic",
	"fontSize",
	"fontWeight",
	"id",
	"layoutHeight",
	"layoutWeight",
	"layoutWidth",
	"margins",
	"maxHeight",
	"maxWidth",
	"minHeight",
	"minWidth",
	"padding",
	"parent",
	"resetState",
	"setState",
	"state",
	"styleId",
	"tabOrder",
	"text",
	"textColor",
	"textFlags",
	"trackHover",
	"visibility",
	"window"
];
//dfmt on
