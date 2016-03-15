import std.stdio;
import lnk;

void main(string[] args)
{
    if (args.length < 2) {
        stderr.writeln("Expected input file");
        return;
    }

    auto link = new ShellLink(args[1]);
    writeln("Description: ", link.description);
    writeln("Relative path: ", link.relativePath);
    writeln("Working directory: ", link.workingDirectory);
    version(Windows) {
        writefln("Arguments: %(%s %)", link.arguments);
    } else {
        writeln("Arguments: ", link.argumentsString);
    }
    uint iconIndex;
    auto iconLocation = link.getIconLocation(iconIndex);
    writefln("Icon location: %s. Icon index: %s", iconLocation, iconIndex);
    writeln("Resolve: ", link.resolve());
}
