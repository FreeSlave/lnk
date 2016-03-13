
module lnk;

private {
    import std.traits;
    import std.bitmanip;
    import std.file;
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

class ShellLinkException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) pure nothrow @safe {
        super(msg, file, line, next);
    }
}

/**
 * Access Shell Link objects (.lnk files)
 */
final class ShellLink 
{
private:
    Header _header;
    ubyte[][] _itemIdList;
    LinkInfoHeader _linkInfoHeader;
    Volume _volume;
    
    string _localBasePath;
    string _commonPathSuffix;
    
    string _name;
    string _relativePath;
    string _workingDir;
    string _arguments;
    string _iconLocation;
    
    string _fileName;
    
public:
    /**
     * Read Shell Link from fileName.
     * Note: file will be read as whole.
     */
    @trusted this(string fileName)
    {
        this(cast(const(ubyte)[])read(fileName), fileName);
    }

    /**
     * Read Shell Link from data.
     */
    @safe this(const(ubyte)[] data, string fileName = null)
    {
        _fileName = fileName;
        auto headerSize = readValue!uint(data);
        enforce!ShellLinkException(headerSize == Header.requiredHeaderSize, "Wrong Shell Link Header size");
        auto headerData = eatSlice(data, headerSize);
        _header = parseHeader(headerData);
        
        if (_header.linkFlags & HasLinkTargetIDList) {
            auto idListSize = eatValue!ushort(data);
            auto idListData = eatSlice(data, idListSize);
            _itemIdList = parseItemIdList(idListData);
        }
        
        if (_header.linkFlags & HasLinkInfo) {
            auto linkInfoSize = readValue!uint(data);
            auto linkInfoData = eatSlice(data, linkInfoSize);
            _linkInfoHeader = parseLinkInfo(linkInfoData);
            
            if (_linkInfoHeader.localBasePathOffsetUnicode) {
                _localBasePath = readWString(linkInfoData[_linkInfoHeader.localBasePathOffsetUnicode..$]).toUTF8();
            } else if (_linkInfoHeader.localBasePathOffset) {
                _localBasePath = readString(linkInfoData[_linkInfoHeader.localBasePathOffset..$]).idup;
            }
            if (_linkInfoHeader.commonPathSuffixOffsetUnicode) {
                _commonPathSuffix = readWString(linkInfoData[_linkInfoHeader.commonPathSuffixOffsetUnicode..$]).toUTF8();
            } else if (_linkInfoHeader.commonPathSuffixOffset) {
                _commonPathSuffix = readString(linkInfoData[_linkInfoHeader.commonPathSuffixOffset..$]).idup;
            }
            
            if (_linkInfoHeader.flags & VolumeIDAndLocalBasePath && _linkInfoHeader.volumeIdOffset) {
                auto volumeIdSize = readValue!uint(linkInfoData[_linkInfoHeader.volumeIdOffset..$]);
                enforce!ShellLinkException(volumeIdSize > 0x10, "Wrong VolumeID size");
                auto volumeIdData = readSlice(linkInfoData[_linkInfoHeader.volumeIdOffset..$], volumeIdSize);
                _volume = parseVolumeData(volumeIdData);
            }
        }
        
        if (_header.linkFlags & HasName) {
            _name = consumeStringData(data);
        }
        if (_header.linkFlags & HasRelativePath) {
            _relativePath = consumeStringData(data);
        }
        if (_header.linkFlags & HasWorkingDir) {
            _workingDir = consumeStringData(data);
        }
        if (_header.linkFlags & HasArguments) {
            _arguments = consumeStringData(data);
        }
        if (_header.linkFlags & HasIconLocation) {
            _iconLocation = consumeStringData(data);
        }
    }
    
    /**
     * Get description of for a Shell Link object.
     */
    @nogc @safe string description() const {
        return _name;
    }
    
    /**
     * Get relative path of for a Shell Link object.
     */
    @nogc @safe string relativePath() const {
        return _relativePath;
    }
    
    /**
     * Get working directory of for a Shell Link object.
     */
    @nogc @safe string workingDirectory() const {
        return _workingDir;
    }
    
    /**
     * Get arguments of for a Shell Link object as one string (target file path is not included)
     */
    @nogc @safe string argumentsString() const {
        return _arguments;
    }
    
    /**
     * Get icon location of for a Shell Link object.
     */
    @nogc @safe string iconLocation() const {
        return _iconLocation;
    }
    
    /**
     * Resolve target file location.
     */
    @safe string resolve() const {
        return _localBasePath ~ _commonPathSuffix;
    }
    
    /**
     * Get path of link object as was specified upon constructing.
     */
    @nogc @safe string fileName() const {
        return _fileName;
    }
    
private:
    @trusted static string consumeStringData(ref const(ubyte)[] data)
    {
        auto size = eatValue!ushort(data);
        return eatSlice!wchar(data, size).toUTF8();
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
        uint iconIndex;
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
        header.iconIndex = eatValue!uint(headerData);
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
}
