# LNK

D library for parsing Shell Link files (.lnk aka shortcuts). 

[![Build Status](https://travis-ci.org/FreeSlave/lnk.svg?branch=master)](https://travis-ci.org/FreeSlave/lnk) [![Windows Build Status](https://ci.appveyor.com/api/projects/status/github/FreeSlave/lnk?branch=master&svg=true)](https://ci.appveyor.com/project/FreeSlave/lnk)

No IShellLink COM interface is used. Instead the library implements parsing of 
.lnk files itself according to [Shell Link Binary File Format](https://msdn.microsoft.com/en-us/library/dd871305.aspx) specification.

Using of WinAPI is minimized too, so the library can be used on other platforms 
than Windows (Although there's little sense for it).

**Note:** it's not fully implemented yet.

## Examples

### [ReadLnk](examples/readlnk/source/app.d)

Run to parse .lnk file and print results to stdout:

    dub run lnk:readlnk -- somelink.lnk

Note that running this in cmd.exe console may print garbage characters if 
link's target has unicode characters in its name. So it's better to redirect output to file.

    dub run lnk:readlnk -- somelink.lnk > test.txt
