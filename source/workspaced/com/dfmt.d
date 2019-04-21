module workspaced.com.dfmt;

import fs = std.file;
import std.array;
import std.conv;
import std.getopt;
import std.json;
import std.stdio : stderr;

import dfmt.config;
import dfmt.editorconfig;
import dfmt.formatter : fmt = format;

import core.thread;

import painlessjson;

import workspaced.api;

@component("dfmt")
class DfmtComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	/// Will format the code passed in asynchronously.
	/// Returns: the formatted code as string
	Future!string format(scope const(char)[] code, string[] arguments = [])
	{
		auto ret = new Future!string;
		threads.create({
			try
			{
				Config config;
				config.initializeWithDefaults();
				string configPath;
				if (getConfigPath("dfmt.json", configPath))
				{
					stderr.writeln("Overriding dfmt arguments with workspace-d dfmt.json config file");
					try
					{
						auto json = parseJSON(fs.readText(configPath));
						json.tryFetchProperty(config.dfmt_align_switch_statements, "align_switch_statements");
						json.tryFetchProperty(config.dfmt_brace_style, "brace_style");
						json.tryFetchProperty(config.end_of_line, "end_of_line");
						json.tryFetchProperty(config.indent_size, "indent_size");
						json.tryFetchProperty(config.indent_style, "indent_style");
						json.tryFetchProperty(config.max_line_length, "max_line_length");
						json.tryFetchProperty(config.dfmt_soft_max_line_length, "soft_max_line_length");
						json.tryFetchProperty(config.dfmt_outdent_attributes, "outdent_attributes");
						json.tryFetchProperty(config.dfmt_space_after_cast, "space_after_cast");
						json.tryFetchProperty(config.dfmt_space_after_keywords, "space_after_keywords");
						json.tryFetchProperty(config.dfmt_split_operator_at_line_end,
							"split_operator_at_line_end");
						json.tryFetchProperty(config.tab_width, "tab_width");
						json.tryFetchProperty(config.dfmt_selective_import_space, "selective_import_space");
						json.tryFetchProperty(config.dfmt_compact_labeled_statements,
							"compact_labeled_statements");
						json.tryFetchProperty(config.dfmt_template_constraint_style,
							"template_constraint_style");
					}
					catch (Exception e)
					{
						stderr.writeln("dfmt.json in workspace-d config folder is malformed");
						stderr.writeln(e);
					}
				}
				else if (arguments.length)
				{
					void handleBooleans(string option, string value)
					{
						import dfmt.editorconfig : OptionalBoolean;
						import std.exception : enforce;

						enforce!GetOptException(value == "true" || value == "false", "Invalid argument");
						immutable OptionalBoolean val = value == "true" ? OptionalBoolean.t : OptionalBoolean.f;
						switch (option)
						{
						case "align_switch_statements":
							config.dfmt_align_switch_statements = val;
							break;
						case "outdent_attributes":
							config.dfmt_outdent_attributes = val;
							break;
						case "space_after_cast":
							config.dfmt_space_after_cast = val;
							break;
						case "split_operator_at_line_end":
							config.dfmt_split_operator_at_line_end = val;
							break;
						case "selective_import_space":
							config.dfmt_selective_import_space = val;
							break;
						case "compact_labeled_statements":
							config.dfmt_compact_labeled_statements = val;
							break;
						default:
							throw new Exception("Invalid command-line switch");
						}
					}

					arguments = "dfmt" ~ arguments;
					//dfmt off
					getopt(arguments,
						"align_switch_statements", &handleBooleans,
						"brace_style", &config.dfmt_brace_style,
						"end_of_line", &config.end_of_line,
						"indent_size", &config.indent_size,
						"indent_style|t", &config.indent_style,
						"max_line_length", &config.max_line_length,
						"soft_max_line_length", &config.dfmt_soft_max_line_length,
						"outdent_attributes", &handleBooleans,
						"space_after_cast", &handleBooleans,
						"selective_import_space", &handleBooleans,
						"split_operator_at_line_end", &handleBooleans,
						"compact_labeled_statements", &handleBooleans,
						"tab_width", &config.tab_width,
						"template_constraint_style", &config.dfmt_template_constraint_style);
					//dfmt on
				}
				auto output = appender!string;
				fmt("stdin", cast(ubyte[]) code, output, &config);
				if (output.data.length)
					ret.finish(output.data);
				else
					ret.finish(code.idup);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}
}

private:

void tryFetchProperty(T = string)(ref JSONValue json, ref T ret, string name)
{
	auto ptr = name in json;
	if (ptr)
	{
		auto val = *ptr;
		static if (is(T == string) || is(T == enum))
		{
			if (val.type != JSON_TYPE.STRING)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a string");
			static if (is(T == enum))
				ret = val.str.to!T;
			else
				ret = val.str;
		}
		else static if (is(T == uint))
		{
			if (val.type != JSON_TYPE.INTEGER)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a number");
			if (val.integer < 0)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a positive number");
			ret = cast(T) val.integer;
		}
		else static if (is(T == int))
		{
			if (val.type != JSON_TYPE.INTEGER)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a number");
			ret = cast(T) val.integer;
		}
		else static if (is(T == OptionalBoolean))
		{
			if (val.type != JSON_TYPE.TRUE && val.type != JSON_TYPE.FALSE)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a boolean");
			ret = val.type == JSON_TYPE.TRUE ? OptionalBoolean.t : OptionalBoolean.f;
		}
		else
			static assert(false);
	}
}
