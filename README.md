# LNK

D library for parsing Shell Link files (.lnk aka shortcuts). 
No IShellLink COM interface is used. Instead the library implements parsing of 
.lnk files itself according to [Shell Link Binary File Format](https://msdn.microsoft.com/en-us/library/dd871305.aspx) specification.
Using of WinAPI is minimized too, so the library can be used on other platforms than Windows (Although there's little sense for it).