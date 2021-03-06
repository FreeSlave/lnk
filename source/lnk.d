/**
 * Parse Shell Link files (.lnk).
 * Authors: 
 *  $(LINK2 https://github.com/FreeSlave, Roman Chistokhodov)
 * Copyright:
 *  Roman Chistokhodov, 2016
 * License: 
 *  $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * See_Also: 
 *  $(LINK2 https://msdn.microsoft.com/en-us/library/dd871305.aspx, Shell Link Binary File Format)
 */

module lnk;

private {
    import std.traits;
    import std.bitmanip;
    import std.file;
    import std.path;
    import std.system;
    import std.exception;
    import std.utf;
}

private @nogc @trusted void swapByteOrder(T)(ref T t) nothrow pure  {
    
    static if( __VERSION__ < 2067 ) { //swapEndian was not @nogc
        ubyte[] bytes = (cast(ubyte*)&t)[0..T.sizeof];
        for (size_t i=0; i<bytes.length/2; ++i) {
            ubyte tmp = bytes[i];
            bytes[i] = bytes[T.sizeof-1-i];
            bytes[T.sizeof-1-i] = tmp;
        }
    } else {
        t = swapEndian(t);
    }
}

private @trusted T readValue(T)(const(ubyte)[] data) if (isIntegral!T || isSomeChar!T)
{
    if (data.length >= T.sizeof) {
        T value = *(cast(const(T)*)data[0..T.sizeof].ptr);
        static if (endian == Endian.bigEndian) {
            swapByteOrder(value);
        }
        return value;
    } else {
        throw new ShellLinkException("Value of requrested size is out of data bounds");
    }
}

private @trusted T eatValue(T)(ref const(ubyte)[] data) if (isIntegral!T || isSomeChar!T)
{
    auto value = readValue!T(data);
    data = data[T.sizeof..$];
    return value;
}

private @trusted const(T)[] readSlice(T = ubyte)(const(ubyte)[] data, size_t count) if (isIntegral!T || isSomeChar!T)
{
    if (data.length >= count*T.sizeof) {
        return cast(typeof(return))data[0..count*T.sizeof];
    } else {
        throw new ShellLinkException("Slice of requsted size is out of data bounds");
    }
}

private @trusted const(T)[] eatSlice(T = ubyte)(ref const(ubyte)[] data, size_t count) if (isIntegral!T || isSomeChar!T)
{
    auto slice = readSlice!T(data, count);
    data = data[count*T.sizeof..$];
    return slice;
}

private @trusted const(char)[] readString(const(ubyte)[] data)
{
    auto str = cast(const(char)[])data;
    for (size_t i=0; i<str.length; ++i) {
        if (data[i] == 0) {
            return str[0..i];
        }
    }
    throw new ShellLinkException("Could not read null-terminated string");
}

private @trusted const(wchar)[] readWString(const(ubyte)[] data)
{
    auto possibleWcharCount = data.length/2; //to chop the last byte if count is odd, avoid misalignment
    auto str = cast(const(wchar)[])data[0..possibleWcharCount*2];
    for (size_t i=0; i<str.length; ++i) {
        if (str[i] == 0) {
            return str[0..i];
        }
    }
    throw new ShellLinkException("Could not read null-terminated wide string");
}


/**
 * Exception thrown if shell link file data could not be parsed.
 */
final class ShellLinkException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) pure nothrow @safe {
        super(msg, file, line, next);
    }
}

version(Windows) {
    import core.sys.windows.windows : CommandLineToArgvW, LocalFree;
    import core.stdc.wchar_;
    
    private @trusted string[] parseCommandLine(string commandLine)
    {
        auto wCommandLineZ = ("Dummy.exe " ~ commandLine).toUTF16z();
        int argc;
        auto argv = CommandLineToArgvW(wCommandLineZ, &argc);
        if (argv is null || argc == 0) {
            return null;
        }
        scope(exit) LocalFree(argv);
        
        string[] args;
        args.length = argc-1;
        for (size_t i=0; i<args.length; ++i) {
            args[i] = argv[i+1][0..wcslen(argv[i+1])].toUTF8();
        }
        return args;
    }
}

private @trusted string fromANSIToUnicode(const(char)[] ansi)
{
    //Don't convert ascii.
    bool needConvert;
    for (size_t i=0; i<ansi.length; ++i) {
        if (!(ansi[i] >= 0 && ansi[i] < 0x80)) {
            needConvert = true;
            break;
        }
    }
    if (!needConvert) {
        return ansi.idup;
    }

    version(Windows) {
        import core.sys.windows.windows : MultiByteToWideChar;
        auto requiredLength = MultiByteToWideChar(0, 0, ansi.ptr, cast(int)ansi.length, null, 0);
        if (requiredLength) {
            auto wstr = new wchar[requiredLength];
            auto bytesWritten = MultiByteToWideChar(0, 0, ansi.ptr, cast(int)ansi.length, wstr.ptr, cast(int)wstr.length);
            if (bytesWritten) {
                if (wstr[$-1] == 0) {
                    wstr = wstr[0..$-1];
                }
                return wstr.toUTF8();
            }
        }
        return null;
    } else {
        ///TODO: implement for non-Windows.
        return ansi.idup;
    }
}

private interface DataReader
{
    uint readInt();
    ushort eatShort();
    const(ubyte)[] eatBytes(size_t count);
    const(wchar)[] eatUnicode(size_t count);
}

private final class FileReader : DataReader
{
    import std.stdio : File, stderr;

    this(string fileName) {
        _file = File(fileName);
    }
    
    uint readInt() {
        _wasRead = true;
        return readValue!uint(_file.rawRead(_read[]));
    }
    
    ushort eatShort() {
        ubyte[ushort.sizeof] shortBuf;
        return readValue!ushort(_file.rawRead(shortBuf[]));
    }
    
    const(ubyte)[] eatBytes(size_t count) {
        enforce!ShellLinkException(!_wasRead || count >= _read.length, "Invalid data size");
        auto buf = new ubyte[count - (_wasRead ? _read.length : 0)];
        auto toReturn = (_wasRead ? _read[] : (ubyte[]).init) ~ _file.rawRead(buf);
        _wasRead = false;
        return toReturn;
    }
    
    const(wchar)[] eatUnicode(size_t count) {
        auto buf = new wchar[count];
        return _file.rawRead(buf);
    }
    
private:
    File _file;
    ubyte[uint.sizeof] _read;
    bool _wasRead;
}

private final class BufferReader : DataReader
{
    this(const(ubyte)[] data) {
        _data = data;
    }
    
    uint readInt() {
        return readValue!uint(_data);
    }
    
    ushort eatShort() {
        return eatValue!ushort(_data);
    }
    
    const(ubyte)[] eatBytes(size_t count) {
        return eatSlice(_data, count);
    }
    
    const(wchar)[] eatUnicode(size_t count) {
        return eatSlice!wchar(_data, count);
    }
    
private:
    const(ubyte)[] _data;
}

/**
 * Class for accessing Shell Link objects (.lnk files)
 */
final class ShellLink 
{
private:
    Header _header;
    ubyte[][] _itemIdList;
    LinkInfoHeader _linkInfoHeader;
    Volume _volume;
    CommonNetworkRelativeLink _networkLink;
    
    string _localBasePath;
    string _commonPathSuffix;
    
    string _description;
    string _relativePath;
    string _workingDir;
    string _arguments;
    string _iconLocation;
    
    string _netName;
    string _deviceName;
    
    string _fileName;
    
public:
    /**
     * Read Shell Link from fileName.
     * Throws: 
     *  ErrnoException if file could not be read.
     *  ShellLinkException if file could not be parsed.
     * Note: file will be read as whole.
     */
    @trusted this(string fileName)
    {
        this(new FileReader(fileName));
    }
    
    @trusted this(const(ubyte)[] data, string fileName = null)
    {
        this(new BufferReader(data), fileName);
    }

    /**
     * Read Shell Link from data. fileName should be path to the .lnk file where data was read from.
     * Throws:
     *  ShellLinkException if data could not be parsed.
     */
    private @trusted this(DataReader reader, string fileName = null)
    {
        _fileName = fileName;
        auto headerSize = reader.readInt();
        enforce!ShellLinkException(headerSize == Header.requiredHeaderSize, "Wrong Shell Link Header size");
        auto headerData = reader.eatBytes(headerSize);
        _header = parseHeader(headerData);
        
        if (_header.linkFlags & HasLinkTargetIDList) {
            auto idListSize = reader.eatShort();
            auto idListData = reader.eatBytes(idListSize);
            _itemIdList = parseItemIdList(idListData);
        }
        
        if (_header.linkFlags & HasLinkInfo) {
            auto linkInfoSize = reader.readInt();
            auto linkInfoData = reader.eatBytes(linkInfoSize);
            _linkInfoHeader = parseLinkInfo(linkInfoData);
            
            if (_linkInfoHeader.localBasePathOffsetUnicode) {
                _localBasePath = readWString(linkInfoData[_linkInfoHeader.localBasePathOffsetUnicode..$]).toUTF8();
            } else if (_linkInfoHeader.localBasePathOffset) {
                auto str = readString(linkInfoData[_linkInfoHeader.localBasePathOffset..$]);
                _localBasePath = fromANSIToUnicode(str);
            }
            if (_linkInfoHeader.commonPathSuffixOffsetUnicode) {
                _commonPathSuffix = readWString(linkInfoData[_linkInfoHeader.commonPathSuffixOffsetUnicode..$]).toUTF8();
            } else if (_linkInfoHeader.commonPathSuffixOffset) {
                auto str = readString(linkInfoData[_linkInfoHeader.commonPathSuffixOffset..$]);
                _commonPathSuffix = fromANSIToUnicode(str);
            }
            
            if (_linkInfoHeader.flags & VolumeIDAndLocalBasePath && _linkInfoHeader.volumeIdOffset) {
                auto volumeIdSize = readValue!uint(linkInfoData[_linkInfoHeader.volumeIdOffset..$]);
                enforce!ShellLinkException(volumeIdSize > Volume.minimumSize, "Wrong VolumeID size");
                auto volumeIdData = readSlice(linkInfoData[_linkInfoHeader.volumeIdOffset..$], volumeIdSize);
                _volume = parseVolumeData(volumeIdData);
            }
            
            if (_linkInfoHeader.flags & CommonNetworkRelativeLinkAndPathSuffix && _linkInfoHeader.commonNetworkRelativeLinkOffset) {
                auto networkLinkSize = readValue!uint(linkInfoData[_linkInfoHeader.commonNetworkRelativeLinkOffset..$]);
                enforce!ShellLinkException(networkLinkSize >= CommonNetworkRelativeLink.minimumSize, "Wrong common network relative path link size");
                auto networkLinkData = readSlice(linkInfoData[_linkInfoHeader.commonNetworkRelativeLinkOffset..$], networkLinkSize);
                _networkLink = parseNetworkLink(networkLinkData);
                
                if (_networkLink.netNameOffsetUnicode) {
                    _netName = readWString(networkLinkData[_networkLink.netNameOffsetUnicode..$]).toUTF8();
                } else if (_networkLink.netNameOffset) {
                    auto str = readString(networkLinkData[_networkLink.netNameOffset..$]);
                    _netName = fromANSIToUnicode(str);
                }
                
                if (_networkLink.deviceNameOffsetUnicode) {
                    _deviceName = readWString(networkLinkData[_networkLink.deviceNameOffsetUnicode..$]).toUTF8();
                } else if (_networkLink.deviceNameOffset) {
                    auto str = readString(networkLinkData[_networkLink.deviceNameOffset..$]);
                    _deviceName = fromANSIToUnicode(str);
                }
            }
        }
        
        if (_header.linkFlags & HasName) {
            _description = consumeStringData(reader);
        }
        if (_header.linkFlags & HasRelativePath) {
            _relativePath = consumeStringData(reader);
        }
        if (_header.linkFlags & HasWorkingDir) {
            _workingDir = consumeStringData(reader);
        }
        if (_header.linkFlags & HasArguments) {
            _arguments = consumeStringData(reader);
        }
        if (_header.linkFlags & HasIconLocation) {
            _iconLocation = consumeStringData(reader);
        }
    }
    
    /**
     * Get description for a Shell Link object.
     */
    @nogc @safe string description() const nothrow {
        return _description;
    }
    
    /**
     * Get relative path for a Shell Link object.
     */
    @nogc @safe string relativePath() const nothrow {
        return _relativePath;
    }
    
    /**
     * Get working directory for a Shell Link object.
     */
    @nogc @safe string workingDirectory() const nothrow {
        return _workingDir;
    }
    
    /**
     * Get arguments of for a Shell Link object as one string. Target file path is NOT included.
     */
    @nogc @safe string argumentsString() const nothrow {
        return _arguments;
    }
    
    version(Windows) {
        /**
         * Get command line arguments. Target file path is NOT included.
         * Note: This function is Windows only. Currently this function allocates on each call.
         */
        @safe string[] arguments() const {
            return parseCommandLine(_arguments);
        }
    }
    
    /**
     * Icon location to be used when displaying a shell link item in an icon view. 
     * Icon location can be of program (.exe), library (.dll) or icon (.ico).
     * Returns: Location of icon or empty string if not specified.
     * Params:
     *  iconIndex = The index of an icon within a given icon location.
     * Note: Icon location may contain environment variable within. It lefts as is if expanding failed.
     */
    @trusted string getIconLocation(out int iconIndex) const  {
        iconIndex = _header.iconIndex;
        version(Windows) {
            import core.sys.windows.windows : ExpandEnvironmentStringsW, DWORD;
            import std.process : environment;
            
            auto wstrz = _iconLocation.toUTF16z();
            if (wstrz) {
                auto requiredLength = ExpandEnvironmentStringsW(wstrz, null, 0);
                auto buffer = new wchar[requiredLength];
                auto result = ExpandEnvironmentStringsW(wstrz, buffer.ptr, cast(DWORD)buffer.length);
                if (result) {
                    if (buffer[$-1] == 0) {
                        buffer = buffer[0..$-1];
                    }
                    return buffer.toUTF8();
                }
            }
        }
        return _iconLocation;
    }
    
    version(Windows) {
        /**
        * Resolve link target location. Windows-only.
        * Returns: Resolved location of link target or null if evaluated path does not exist or target location could not be resolved.
        * Note: In case path parts were stored only as ANSI 
        * the result string may contain garbage characters 
        * if user changed default code page and shell link had not get updated yet.
        * If path parts were stored as Unicode it should not have problems.
        */
        @safe string resolve() const nothrow {
            string targetPath;
            bool pathExists;
            
            if (_localBasePath.length) {
                if (_commonPathSuffix.length) {
                    targetPath = _localBasePath ~ _commonPathSuffix;
                    pathExists = targetPath.exists;
                } else if (_localBasePath.isAbsolute) {
                    targetPath = _localBasePath;
                    pathExists = targetPath.exists;
                }
            }
            
            if (!pathExists && _relativePath.length && _workingDir.length) {
                targetPath = buildPath(_workingDir, _relativePath);
                pathExists = targetPath.exists;
            }
            
            if (!pathExists && _netName.length) {
                if (_commonPathSuffix.length) {
                    targetPath = _netName ~ '\\' ~ _commonPathSuffix;
                    pathExists = targetPath.exists;
                } else if (_netName.isAbsolute) {
                    targetPath = _netName;
                    pathExists = targetPath.exists;
                }
            }
            
            if (pathExists) {
                return buildNormalizedPath(targetPath);
            } else {
                return null;
            } 
        }
    }
    
    /**
     * Get path of link object as was specified upon constructing.
     */
    @nogc @safe string fileName() const nothrow {
        return _fileName;
    }
    
    /**
     * The name of a shell link, i.e. part of file name with directory and extension parts stripped.
     */
    @nogc @safe string name() const nothrow {
        return _fileName.baseName.stripExtension;
    }
    
    /**
     * The expected window state of an application launched by the link.
     * See_Also: $(LINK2 https://msdn.microsoft.com/en-us/library/windows/desktop/ms633548(v=vs.85).aspx, ShowWindow)
     */
    enum ShowCommand : uint {
        normal = 0x1, ///The application is open and its window is open in a normal fashion.
        maximized = 0x3, ///The application is open, and keyboard focus is given to the application, but its window is not shown.
        minNoActive = 0x7 ///The application is open, but its window is not shown. It is not given the keyboard focus.
    }
    
    /**
     * The expected window state of an application launched by the link.
     * See $(LINK2 https://msdn.microsoft.com/en-us/library/windows/desktop/ms633548(v=vs.85).aspx, ShowWindow).
     */
    @nogc @safe ShowCommand showCommand() const nothrow {
        switch(_header.showCommand) {
            case ShowCommand.normal:
            case ShowCommand.maximized:
            case ShowCommand.minNoActive:
                return cast(ShowCommand)_header.showCommand;
            default:
                return ShowCommand.normal;
        }
    }
    
    /**
     * Get hot key used to start link target.
     * Returns: 2-byte value with virtual key code in low byte and 
     * $(LINK2 https://msdn.microsoft.com/en-us/library/windows/desktop/ms646278(v=vs.85).aspx, modifier keys) in high byte.
     */
    @nogc @safe uint hotKey() const nothrow {
        return _header.hotKey;
    }
    
private:
    @trusted static string consumeStringData(DataReader reader)
    {
        auto size = reader.eatShort();
        return reader.eatUnicode(size).toUTF8();
    }

    enum : uint {
        HasLinkTargetIDList = 1 << 0,
        HasLinkInfo = 1 << 1,
        HasName = 1 << 2,
        HasRelativePath = 1 << 3,
        HasWorkingDir = 1 << 4,
        HasArguments = 1 << 5,
        HasIconLocation = 1 << 6,
        IsUnicode = 1 << 7,
        ForceNoLinkInfo = 1 << 8,
        HasExpString = 1 << 9,
        RunInSeparateProcess = 1 << 10,
        Unused1 = 1 << 11,
        HasDarwinID = 1 << 12,
        RunAsUser = 1 << 13,
        HasExpIcon = 1 << 14,
        NoPidlAlias = 1 << 15,
        Unused2 = 1 << 16,
        RunWithShimLayer = 1 << 17,
        ForceNoLinkTrack = 1 << 18,
        EnableTargetMetadata = 1 << 19,
        DisableLinkPathTracking = 1 << 20,
        DisableKnownFolderTracking = 1 << 21,
        DisableKnownFolderAlias = 1 << 22,
        AllowLinkToLink = 1 << 23,
        UnaliasOnSave = 1 << 24,
        PreferEnvironmentPath = 1 << 25,
        KeepLocalIDListForUNCTarget = 1 << 26
    }

    struct Header
    {
        alias ubyte[16] CLSID;

        enum uint requiredHeaderSize = 0x0000004C;
        enum CLSID requiredLinkCLSID = [1, 20, 2, 0, 0, 0, 0, 0, 192, 0, 0, 0, 0, 0, 0, 70];
        uint headerSize;
        CLSID linkCLSID;
        uint linkFlags;
        uint fileAttributes;
        ulong creationTime;
        ulong accessTime;
        ulong writeTime;
        uint fileSize;
        int iconIndex;
        uint showCommand;
        
        enum {
            SW_SHOWNORMAL = 0x00000001,
            SW_SHOWMAXIMIZED = 0x00000003,
            SW_SHOWMINNOACTIVE = 0x00000007
        }
        
        ushort hotKey;
        ushort reserved1;
        uint reserved2;
        uint reserved3;
    }

    @trusted static Header parseHeader(const(ubyte)[] headerData)
    {
        Header header;
        header.headerSize = eatValue!uint(headerData);
        auto linkCLSIDSlice = eatSlice(headerData, 16);
        
        enforce!ShellLinkException(linkCLSIDSlice == Header.requiredLinkCLSID[], "Invalid Link CLSID");
        for (size_t i=0; i<16; ++i) {
            header.linkCLSID[i] = linkCLSIDSlice[i];
        }
        
        header.linkFlags = eatValue!uint(headerData);
        
        header.fileAttributes = eatValue!uint(headerData);
        header.creationTime = eatValue!ulong(headerData);
        header.accessTime = eatValue!ulong(headerData);
        header.writeTime = eatValue!ulong(headerData);
        header.fileSize = eatValue!uint(headerData);
        header.iconIndex = eatValue!int(headerData);
        header.showCommand = eatValue!uint(headerData);
        header.hotKey = eatValue!ushort(headerData);
        
        header.reserved1 = eatValue!ushort(headerData);
        header.reserved2 = eatValue!uint(headerData);
        header.reserved3 = eatValue!uint(headerData);
        return header;
    }
    
    @trusted static ubyte[][] parseItemIdList(const(ubyte)[] idListData) 
    {
        ubyte[][] itemIdList;
        while(true) {
            auto itemSize = eatValue!ushort(idListData);
            if (itemSize) {
                enforce(itemSize >= 2, "Item size must be at least 2");
                auto dataSize = itemSize - 2;
                auto itemData = eatSlice(idListData, dataSize);
                itemIdList ~= itemData.dup;
            } else {
                break;
            }
        }
        return itemIdList;
    }
    
    enum {
        VolumeIDAndLocalBasePath = 1 << 0,
        CommonNetworkRelativeLinkAndPathSuffix = 1 << 1
    }
    
    struct LinkInfoHeader
    {
        enum uint defaultHeaderSize = 0x1C;
        enum uint minimumExtendedHeaderSize = 0x24;
    
        uint infoSize;
        uint headerSize;
        uint flags;
        uint volumeIdOffset;
        uint localBasePathOffset;
        uint commonNetworkRelativeLinkOffset;
        uint commonPathSuffixOffset;
        uint localBasePathOffsetUnicode;
        uint commonPathSuffixOffsetUnicode;
    }
    
    @trusted static LinkInfoHeader parseLinkInfo(const(ubyte[]) linkInfoData)
    {
        LinkInfoHeader linkInfoHeader;
        linkInfoHeader.infoSize = readValue!uint(linkInfoData);
        linkInfoHeader.headerSize = readValue!uint(linkInfoData[uint.sizeof..$]);
        
        auto linkInfoHeaderData = readSlice(linkInfoData, linkInfoHeader.headerSize);
        eatSlice(linkInfoHeaderData, uint.sizeof*2);
        
        linkInfoHeader.flags = eatValue!uint(linkInfoHeaderData);
        linkInfoHeader.volumeIdOffset = eatValue!uint(linkInfoHeaderData);
        linkInfoHeader.localBasePathOffset = eatValue!uint(linkInfoHeaderData);
        linkInfoHeader.commonNetworkRelativeLinkOffset = eatValue!uint(linkInfoHeaderData);
        linkInfoHeader.commonPathSuffixOffset = eatValue!uint(linkInfoHeaderData);
        
        if (linkInfoHeader.headerSize == LinkInfoHeader.defaultHeaderSize) {
            //ok, no additional fields
        } else if (linkInfoHeader.headerSize >= LinkInfoHeader.minimumExtendedHeaderSize) {
            linkInfoHeader.localBasePathOffsetUnicode = eatValue!uint(linkInfoHeaderData);
            linkInfoHeader.commonPathSuffixOffsetUnicode = eatValue!uint(linkInfoHeaderData);
        } else {
            throw new ShellLinkException("Bad LinkInfoHeaderSize");
        }
        return linkInfoHeader;
    }
    
    struct Volume
    {
        enum uint minimumSize = 0x10;
        uint size;
        uint driveType;
        uint driveSerialNumber;
        uint labelOffset;
        uint labelOffsetUnicode;
        ubyte[] data;
    }
    
    @trusted static Volume parseVolumeData(const(ubyte)[] volumeIdData)
    {
        Volume volume;
        volume.size = eatValue!uint(volumeIdData);
        volume.driveType = eatValue!uint(volumeIdData);
        volume.driveSerialNumber = eatValue!uint(volumeIdData);
        volume.labelOffset = eatValue!uint(volumeIdData);
        if (volume.labelOffset == 0x14) {
            volume.labelOffsetUnicode = eatValue!uint(volumeIdData);
        }
        volume.data = volumeIdData.dup;
        return volume;
    }
    
    struct CommonNetworkRelativeLink
    {
        enum uint minimumSize = 0x14;
        uint size;
        uint flags;
        uint netNameOffset;
        uint deviceNameOffset;
        uint networkProviderType;
        uint netNameOffsetUnicode;
        uint deviceNameOffsetUnicode;
    }
    
    @trusted static CommonNetworkRelativeLink parseNetworkLink(const(ubyte)[] networkLinkData)
    {
        CommonNetworkRelativeLink networkLink;
        networkLink.size = eatValue!uint(networkLinkData);
        networkLink.flags = eatValue!uint(networkLinkData);
        networkLink.netNameOffset = eatValue!uint(networkLinkData);
        networkLink.deviceNameOffset = eatValue!uint(networkLinkData);
        networkLink.networkProviderType = eatValue!uint(networkLinkData);
        
        if (networkLink.netNameOffset > CommonNetworkRelativeLink.minimumSize) {
            networkLink.netNameOffsetUnicode = eatValue!uint(networkLinkData);
            networkLink.deviceNameOffsetUnicode = eatValue!uint(networkLinkData);
        }
        
        return networkLink;
    }
}
