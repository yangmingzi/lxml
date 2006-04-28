################################################################################
# DEBUG setup

# module level API functions

def clearErrorLog():
    """Clear the global error log.
    Note that this log is already bounded to a fixed size."""
    __GLOBAL_ERROR_LOG.clear()

def initThreadLogging():
    "Setup logging for the current thread."
    _logLibxmlErrors()
    _logLibxsltErrors()


# Logging classes

cdef class _LogEntry:
    cdef readonly object domain
    cdef readonly object type
    cdef readonly object line
    cdef readonly object level
    cdef readonly object message
    cdef readonly object filename
    cdef _set(self, xmlerror.xmlError* error):
        self.domain   = error.domain
        self.type     = error.code
        self.level    = <int>error.level
        self.line     = error.line
        self.message  = python.PyString_FromStringAndSize(
            error.message, tree.strlen(error.message) - 1) # strip EOL
        if error.file is NULL:
            self.filename = '<string>'
        else:
            self.filename = python.PyString_FromString(error.file)

    cdef _setGeneric(self, int domain, int type, int level, int line,
                     message, filename):
        self.domain  = domain
        self.type    = type
        self.level   = level
        self.line    = line
        self.message = message
        self.filename = filename

    def __repr__(self):
        if self.filename:
            return "%s:%d:%s:%s:%s: %s" % (
                self.filename, self.line, self.level_name,
                self.domain_name, self.type_name, self.message)
        else:
            return "[]:%s:%s:%s: %s" % (
                self.level_name, self.domain_name,
                self.type_name, self.message)

    property domain_name:
        def __get__(self):
            return ErrorDomains._names[self.domain]

    property type_name:
        def __get__(self):
            return ErrorTypes._names[self.type]

    property level_name:
        def __get__(self):
            return ErrorLevels._names[self.level]

cdef class _BaseErrorLog:
    "Immutable base version of an error log."
    cdef object _entries
    def __init__(self, entries):
        self._entries = entries

    def copy(self):
        return _BaseErrorLog(self._entries)

    def __iter__(self):
        return iter(self._entries)

    def __repr__(self):
        return '\n'.join(map(repr, self._entries))

    def __getitem__(self, index):
        return self._entries[index]

    def __len__(self):
        return len(self._entries)

    def filter_domains(self, domains):
        cdef _LogEntry entry
        filtered = []
        if not python.PySequence_Check(domains):
            domains = (domains,)
        for entry in self._entries:
            if entry.domain in domains:
                python.PyList_Append(filtered, entry)
        return _BaseErrorLog(filtered)

    def filter_types(self, types):
        cdef _LogEntry entry
        if not python.PySequence_Check(types):
            types = (types,)
        filtered = []
        for entry in self._entries:
            if entry.type in types:
                python.PyList_Append(filtered, entry)
        return _BaseErrorLog(filtered)

    def filter_levels(self, levels):
        """Return a log with all messages of the requested level(s). Takes a
        single log level or a sequence."""
        cdef _LogEntry entry
        if not python.PySequence_Check(levels):
            levels = (levels,)
        filtered = []
        for entry in self._entries:
            if entry.level in levels:
                python.PyList_Append(filtered, entry)
        return _BaseErrorLog(filtered)

    def filter_from_level(self, level):
        "Return a log with all messages of the requested level of worse."
        cdef _LogEntry entry
        filtered = []
        for entry in self._entries:
            if entry.level >= level:
                python.PyList_Append(filtered, entry)
        return _BaseErrorLog(filtered)

    def filter_from_fatals(self):
        "Convenience method to get all fatal error messages."
        return self.filter_from_level(ErrorLevels.FATAL)
    
    def filter_from_errors(self):
        "Convenience method to get all error messages or worse."
        return self.filter_from_level(ErrorLevels.ERROR)
    
    def filter_from_warnings(self):
        "Convenience method to get all warnings or worse."
        return self.filter_from_level(ErrorLevels.WARNING)

cdef class _ErrorLog(_BaseErrorLog):
    def __init__(self):
        _BaseErrorLog.__init__(self, [])

    def clear(self):
        del self._entries[:]

    def copy(self):
        return _BaseErrorLog(self._entries[:])

    def __iter__(self):
        return iter(self._entries[:])

    cdef void connect(self):
        del self._entries[:]
        xmlerror.xmlSetStructuredErrorFunc(<void*>self, _receiveError)

    cdef void disconnect(self):
        xmlerror.xmlSetStructuredErrorFunc(NULL, _receiveError)

    cdef void _receive(self, xmlerror.xmlError* error):
        cdef _LogEntry entry
        entry = _LogEntry()
        entry._set(error)
        if __GLOBAL_ERROR_LOG is not self:
            __GLOBAL_ERROR_LOG.receive(entry)
        self.receive(entry)

    cdef void _receiveGeneric(self, int domain, int type, int level, int line,
                              message, filename):
        cdef _LogEntry entry
        entry = _LogEntry()
        entry._setGeneric(domain, type, level, line, message, filename)
        if __GLOBAL_ERROR_LOG is not self:
            __GLOBAL_ERROR_LOG.receive(entry)
        self.receive(entry)

    def receive(self, entry):
        python.PyList_Append(self._entries, entry)

cdef class _DomainErrorLog(_ErrorLog):
    def receive(self, entry):
        if entry.domain in self._accepted_domains:
            _ErrorLog.receive(self, entry)
    def __init__(self, domains):
        _ErrorLog.__init__(self)
        self._accepted_domains = tuple(domains)

cdef class _RotatingErrorLog(_ErrorLog):
    cdef int _max_len
    def __init__(self, max_len):
        _ErrorLog.__init__(self)
        self._max_len = max_len
    def receive(self, entry):
        entries = self._entries
        if python.PyList_GET_SIZE(entries) > self._max_len:
            del entries[0]
        python.PyList_Append(entries, entry)

cdef class PyErrorLog(_ErrorLog):
    cdef object _log
    cdef object _level_map
    cdef object _varsOf
    def __init__(self, logger_name=None):
        _ErrorLog.__init__(self)
        import logging
        self._level_map = {
            ErrorLevels.WARNING : logging.WARNING,
            ErrorLevels.ERROR   : logging.ERROR,
            ErrorLevels.FATAL   : logging.CRITICAL
            }
        self._varsOf = vars
        if logger_name:
            logger = logging.getLogger(name)
        else:
            logger = logging.getLogger()
        self._log = logger.log

    def copy(self):
        return self

    def receive(self, entry):
        py_level = self._level_map[entry.level]
        self._log(
            py_level,
            "%(asctime)s %(levelname)s %(domain_name)s %(message)s",
            self._varsOf(entry)
            )

# global list to collect error output messages from libxml2/libxslt
cdef _RotatingErrorLog __GLOBAL_ERROR_LOG
__GLOBAL_ERROR_LOG = _RotatingErrorLog(__MAX_LOG_SIZE)

def __copyGlobalErrorLog():
    "Helper function for properties in exceptions."
    return __GLOBAL_ERROR_LOG.copy()

# local log function: forward error to logger object
cdef void _receiveError(void* c_log_handler, xmlerror.xmlError* error):
    cdef _ErrorLog log_handler
    if __DEBUG != 0:
        if c_log_handler is not NULL:
            log_handler = <_ErrorLog>c_log_handler
        else:
            log_handler = __GLOBAL_ERROR_LOG
        log_handler._receive(error)

cdef void _receiveGenericError(void* c_log_handler, char* msg, ...):
    cdef cstd.va_list args
    cdef _ErrorLog log_handler
    cdef char* c_text
    cdef char* c_filename
    cdef char* c_element
    cdef int c_line
    if __DEBUG == 0 or msg == NULL or tree.strlen(msg) < 10:
        return
    if c_log_handler is not NULL:
        log_handler = <_ErrorLog>c_log_handler
    else:
        log_handler = __GLOBAL_ERROR_LOG

    cstd.va_start(args, msg)
    c_text     = cstd.va_charptr(args)
    c_filename = cstd.va_charptr(args)
    c_line     = cstd.va_int(args)
    c_element  = cstd.va_charptr(args)
    cstd.va_end(args)

    if c_text is NULL:
        message = None
    elif c_element is NULL:
        message = funicode(c_text)
    else:
        message = "%s (element '%s')" % (
            funicode(c_text), funicode(c_element))

    if c_filename is not NULL and tree.strlen(c_filename) > 0:
        if tree.strncmp(c_filename, 'XSLT:', 5) == 0:
            filename = '<xslt>'
        else:
            filename = funicode(c_filename)
    else:
        filename = None

    log_handler._receiveGeneric(xmlerror.XML_FROM_XSLT,
                                xmlerror.XML_ERR_OK,
                                xmlerror.XML_ERR_ERROR,
                                c_line, message, filename)

# dummy function: no debug output at all
cdef void _nullGenericErrorFunc(void* ctxt, char* msg, ...):
    pass

# setup for global log:
cdef void _logLibxmlErrors():
    xmlerror.xmlSetGenericErrorFunc(NULL, _nullGenericErrorFunc)
    xmlerror.xmlSetStructuredErrorFunc(NULL, _receiveError)

cdef void _logLibxsltErrors():
    xslt.xsltSetGenericErrorFunc(NULL, _receiveGenericError)

# init global logging
initThreadLogging()

################################################################################
## CONSTANTS FROM "xmlerror.pxd"
################################################################################

class ErrorLevels:
    "Libxml2 error levels"
    _names = {}
    NONE = 0
    WARNING = 1 # A simple warning
    ERROR = 2 # A recoverable error
    FATAL = 3 # A fatal error

class ErrorDomains:
    "Libxml2 error domains"
    _names = {}
    NONE = 0
    PARSER = 1 # The XML parser
    TREE = 2 # The tree module
    NAMESPACE = 3 # The XML Namespace module
    DTD = 4 # The XML DTD validation with parser contex
    HTML = 5 # The HTML parser
    MEMORY = 6 # The memory allocator
    OUTPUT = 7 # The serialization code
    IO = 8 # The Input/Output stack
    FTP = 9 # The FTP module
    HTTP = 10 # The FTP module
    XINCLUDE = 11 # The XInclude processing
    XPATH = 12 # The XPath module
    XPOINTER = 13 # The XPointer module
    REGEXP = 14 # The regular expressions module
    DATATYPE = 15 # The W3C XML Schemas Datatype module
    SCHEMASP = 16 # The W3C XML Schemas parser module
    SCHEMASV = 17 # The W3C XML Schemas validation module
    RELAXNGP = 18 # The Relax-NG parser module
    RELAXNGV = 19 # The Relax-NG validator module
    CATALOG = 20 # The Catalog module
    C14N = 21 # The Canonicalization module
    XSLT = 22 # The XSLT engine from libxslt
    VALID = 23 # The XML DTD validation with valid context
    CHECK = 24 # The error checking module
    WRITER = 25 # The xmlwriter module
    MODULE = 26 # The dynamically loaded module modu

class ErrorTypes:
    "Libxml2 error types"
    _names = {}
    ERR_OK = 0
    ERR_INTERNAL_ERROR = 1
    ERR_NO_MEMORY = 2 
    ERR_DOCUMENT_START = 3 # 3
    ERR_DOCUMENT_EMPTY = 4 # 4
    ERR_DOCUMENT_END = 5 # 5
    ERR_INVALID_HEX_CHARREF = 6 # 6
    ERR_INVALID_DEC_CHARREF = 7 # 7
    ERR_INVALID_CHARREF = 8 # 8
    ERR_INVALID_CHAR = 9 # 9
    ERR_CHARREF_AT_EOF = 10 # 10
    ERR_CHARREF_IN_PROLOG = 11 # 11
    ERR_CHARREF_IN_EPILOG = 12 # 12
    ERR_CHARREF_IN_DTD = 13 # 13
    ERR_ENTITYREF_AT_EOF = 14 # 14
    ERR_ENTITYREF_IN_PROLOG = 15 # 15
    ERR_ENTITYREF_IN_EPILOG = 16 # 16
    ERR_ENTITYREF_IN_DTD = 17 # 17
    ERR_PEREF_AT_EOF = 18 # 18
    ERR_PEREF_IN_PROLOG = 19 # 19
    ERR_PEREF_IN_EPILOG = 20 # 20
    ERR_PEREF_IN_INT_SUBSET = 21 # 21
    ERR_ENTITYREF_NO_NAME = 22 # 22
    ERR_ENTITYREF_SEMICOL_MISSING = 23 # 23
    ERR_PEREF_NO_NAME = 24 # 24
    ERR_PEREF_SEMICOL_MISSING = 25 # 25
    ERR_UNDECLARED_ENTITY = 26 # 26
    WAR_UNDECLARED_ENTITY = 27 # 27
    ERR_UNPARSED_ENTITY = 28 # 28
    ERR_ENTITY_IS_EXTERNAL = 29 # 29
    ERR_ENTITY_IS_PARAMETER = 30 # 30
    ERR_UNKNOWN_ENCODING = 31 # 31
    ERR_UNSUPPORTED_ENCODING = 32 # 32
    ERR_STRING_NOT_STARTED = 33 # 33
    ERR_STRING_NOT_CLOSED = 34 # 34
    ERR_NS_DECL_ERROR = 35 # 35
    ERR_ENTITY_NOT_STARTED = 36 # 36
    ERR_ENTITY_NOT_FINISHED = 37 # 37
    ERR_LT_IN_ATTRIBUTE = 38 # 38
    ERR_ATTRIBUTE_NOT_STARTED = 39 # 39
    ERR_ATTRIBUTE_NOT_FINISHED = 40 # 40
    ERR_ATTRIBUTE_WITHOUT_VALUE = 41 # 41
    ERR_ATTRIBUTE_REDEFINED = 42 # 42
    ERR_LITERAL_NOT_STARTED = 43 # 43
    ERR_LITERAL_NOT_FINISHED = 44 # 44
    ERR_COMMENT_NOT_FINISHED = 45 # 45
    ERR_PI_NOT_STARTED = 46 # 46
    ERR_PI_NOT_FINISHED = 47 # 47
    ERR_NOTATION_NOT_STARTED = 48 # 48
    ERR_NOTATION_NOT_FINISHED = 49 # 49
    ERR_ATTLIST_NOT_STARTED = 50 # 50
    ERR_ATTLIST_NOT_FINISHED = 51 # 51
    ERR_MIXED_NOT_STARTED = 52 # 52
    ERR_MIXED_NOT_FINISHED = 53 # 53
    ERR_ELEMCONTENT_NOT_STARTED = 54 # 54
    ERR_ELEMCONTENT_NOT_FINISHED = 55 # 55
    ERR_XMLDECL_NOT_STARTED = 56 # 56
    ERR_XMLDECL_NOT_FINISHED = 57 # 57
    ERR_CONDSEC_NOT_STARTED = 58 # 58
    ERR_CONDSEC_NOT_FINISHED = 59 # 59
    ERR_EXT_SUBSET_NOT_FINISHED = 60 # 60
    ERR_DOCTYPE_NOT_FINISHED = 61 # 61
    ERR_MISPLACED_CDATA_END = 62 # 62
    ERR_CDATA_NOT_FINISHED = 63 # 63
    ERR_RESERVED_XML_NAME = 64 # 64
    ERR_SPACE_REQUIRED = 65 # 65
    ERR_SEPARATOR_REQUIRED = 66 # 66
    ERR_NMTOKEN_REQUIRED = 67 # 67
    ERR_NAME_REQUIRED = 68 # 68
    ERR_PCDATA_REQUIRED = 69 # 69
    ERR_URI_REQUIRED = 70 # 70
    ERR_PUBID_REQUIRED = 71 # 71
    ERR_LT_REQUIRED = 72 # 72
    ERR_GT_REQUIRED = 73 # 73
    ERR_LTSLASH_REQUIRED = 74 # 74
    ERR_EQUAL_REQUIRED = 75 # 75
    ERR_TAG_NAME_MISMATCH = 76 # 76
    ERR_TAG_NOT_FINISHED = 77 # 77
    ERR_STANDALONE_VALUE = 78 # 78
    ERR_ENCODING_NAME = 79 # 79
    ERR_HYPHEN_IN_COMMENT = 80 # 80
    ERR_INVALID_ENCODING = 81 # 81
    ERR_EXT_ENTITY_STANDALONE = 82 # 82
    ERR_CONDSEC_INVALID = 83 # 83
    ERR_VALUE_REQUIRED = 84 # 84
    ERR_NOT_WELL_BALANCED = 85 # 85
    ERR_EXTRA_CONTENT = 86 # 86
    ERR_ENTITY_CHAR_ERROR = 87 # 87
    ERR_ENTITY_PE_INTERNAL = 88 # 88
    ERR_ENTITY_LOOP = 89 # 89
    ERR_ENTITY_BOUNDARY = 90 # 90
    ERR_INVALID_URI = 91 # 91
    ERR_URI_FRAGMENT = 92 # 92
    WAR_CATALOG_PI = 93 # 93
    ERR_NO_DTD = 94 # 94
    ERR_CONDSEC_INVALID_KEYWORD = 95 # 95
    ERR_VERSION_MISSING = 96 # 96
    WAR_UNKNOWN_VERSION = 97 # 97
    WAR_LANG_VALUE = 98 # 98
    WAR_NS_URI = 99 # 99
    WAR_NS_URI_RELATIVE = 100 # 100
    ERR_MISSING_ENCODING = 101 # 101
    NS_ERR_XML_NAMESPACE = 200
    NS_ERR_UNDEFINED_NAMESPACE = 201 # 201
    NS_ERR_QNAME = 202 # 202
    NS_ERR_ATTRIBUTE_REDEFINED = 203 # 203
    DTD_ATTRIBUTE_DEFAULT = 500
    DTD_ATTRIBUTE_REDEFINED = 501 # 501
    DTD_ATTRIBUTE_VALUE = 502 # 502
    DTD_CONTENT_ERROR = 503 # 503
    DTD_CONTENT_MODEL = 504 # 504
    DTD_CONTENT_NOT_DETERMINIST = 505 # 505
    DTD_DIFFERENT_PREFIX = 506 # 506
    DTD_ELEM_DEFAULT_NAMESPACE = 507 # 507
    DTD_ELEM_NAMESPACE = 508 # 508
    DTD_ELEM_REDEFINED = 509 # 509
    DTD_EMPTY_NOTATION = 510 # 510
    DTD_ENTITY_TYPE = 511 # 511
    DTD_ID_FIXED = 512 # 512
    DTD_ID_REDEFINED = 513 # 513
    DTD_ID_SUBSET = 514 # 514
    DTD_INVALID_CHILD = 515 # 515
    DTD_INVALID_DEFAULT = 516 # 516
    DTD_LOAD_ERROR = 517 # 517
    DTD_MISSING_ATTRIBUTE = 518 # 518
    DTD_MIXED_CORRUPT = 519 # 519
    DTD_MULTIPLE_ID = 520 # 520
    DTD_NO_DOC = 521 # 521
    DTD_NO_DTD = 522 # 522
    DTD_NO_ELEM_NAME = 523 # 523
    DTD_NO_PREFIX = 524 # 524
    DTD_NO_ROOT = 525 # 525
    DTD_NOTATION_REDEFINED = 526 # 526
    DTD_NOTATION_VALUE = 527 # 527
    DTD_NOT_EMPTY = 528 # 528
    DTD_NOT_PCDATA = 529 # 529
    DTD_NOT_STANDALONE = 530 # 530
    DTD_ROOT_NAME = 531 # 531
    DTD_STANDALONE_WHITE_SPACE = 532 # 532
    DTD_UNKNOWN_ATTRIBUTE = 533 # 533
    DTD_UNKNOWN_ELEM = 534 # 534
    DTD_UNKNOWN_ENTITY = 535 # 535
    DTD_UNKNOWN_ID = 536 # 536
    DTD_UNKNOWN_NOTATION = 537 # 537
    DTD_STANDALONE_DEFAULTED = 538 # 538
    DTD_XMLID_VALUE = 539 # 539
    DTD_XMLID_TYPE = 540 # 540
    HTML_STRUCURE_ERROR = 800
    HTML_UNKNOWN_TAG = 801 # 801
    RNGP_ANYNAME_ATTR_ANCESTOR = 1000
    RNGP_ATTR_CONFLICT = 1001 # 1001
    RNGP_ATTRIBUTE_CHILDREN = 1002 # 1002
    RNGP_ATTRIBUTE_CONTENT = 1003 # 1003
    RNGP_ATTRIBUTE_EMPTY = 1004 # 1004
    RNGP_ATTRIBUTE_NOOP = 1005 # 1005
    RNGP_CHOICE_CONTENT = 1006 # 1006
    RNGP_CHOICE_EMPTY = 1007 # 1007
    RNGP_CREATE_FAILURE = 1008 # 1008
    RNGP_DATA_CONTENT = 1009 # 1009
    RNGP_DEF_CHOICE_AND_INTERLEAVE = 1010 # 1010
    RNGP_DEFINE_CREATE_FAILED = 1011 # 1011
    RNGP_DEFINE_EMPTY = 1012 # 1012
    RNGP_DEFINE_MISSING = 1013 # 1013
    RNGP_DEFINE_NAME_MISSING = 1014 # 1014
    RNGP_ELEM_CONTENT_EMPTY = 1015 # 1015
    RNGP_ELEM_CONTENT_ERROR = 1016 # 1016
    RNGP_ELEMENT_EMPTY = 1017 # 1017
    RNGP_ELEMENT_CONTENT = 1018 # 1018
    RNGP_ELEMENT_NAME = 1019 # 1019
    RNGP_ELEMENT_NO_CONTENT = 1020 # 1020
    RNGP_ELEM_TEXT_CONFLICT = 1021 # 1021
    RNGP_EMPTY = 1022 # 1022
    RNGP_EMPTY_CONSTRUCT = 1023 # 1023
    RNGP_EMPTY_CONTENT = 1024 # 1024
    RNGP_EMPTY_NOT_EMPTY = 1025 # 1025
    RNGP_ERROR_TYPE_LIB = 1026 # 1026
    RNGP_EXCEPT_EMPTY = 1027 # 1027
    RNGP_EXCEPT_MISSING = 1028 # 1028
    RNGP_EXCEPT_MULTIPLE = 1029 # 1029
    RNGP_EXCEPT_NO_CONTENT = 1030 # 1030
    RNGP_EXTERNALREF_EMTPY = 1031 # 1031
    RNGP_EXTERNAL_REF_FAILURE = 1032 # 1032
    RNGP_EXTERNALREF_RECURSE = 1033 # 1033
    RNGP_FORBIDDEN_ATTRIBUTE = 1034 # 1034
    RNGP_FOREIGN_ELEMENT = 1035 # 1035
    RNGP_GRAMMAR_CONTENT = 1036 # 1036
    RNGP_GRAMMAR_EMPTY = 1037 # 1037
    RNGP_GRAMMAR_MISSING = 1038 # 1038
    RNGP_GRAMMAR_NO_START = 1039 # 1039
    RNGP_GROUP_ATTR_CONFLICT = 1040 # 1040
    RNGP_HREF_ERROR = 1041 # 1041
    RNGP_INCLUDE_EMPTY = 1042 # 1042
    RNGP_INCLUDE_FAILURE = 1043 # 1043
    RNGP_INCLUDE_RECURSE = 1044 # 1044
    RNGP_INTERLEAVE_ADD = 1045 # 1045
    RNGP_INTERLEAVE_CREATE_FAILED = 1046 # 1046
    RNGP_INTERLEAVE_EMPTY = 1047 # 1047
    RNGP_INTERLEAVE_NO_CONTENT = 1048 # 1048
    RNGP_INVALID_DEFINE_NAME = 1049 # 1049
    RNGP_INVALID_URI = 1050 # 1050
    RNGP_INVALID_VALUE = 1051 # 1051
    RNGP_MISSING_HREF = 1052 # 1052
    RNGP_NAME_MISSING = 1053 # 1053
    RNGP_NEED_COMBINE = 1054 # 1054
    RNGP_NOTALLOWED_NOT_EMPTY = 1055 # 1055
    RNGP_NSNAME_ATTR_ANCESTOR = 1056 # 1056
    RNGP_NSNAME_NO_NS = 1057 # 1057
    RNGP_PARAM_FORBIDDEN = 1058 # 1058
    RNGP_PARAM_NAME_MISSING = 1059 # 1059
    RNGP_PARENTREF_CREATE_FAILED = 1060 # 1060
    RNGP_PARENTREF_NAME_INVALID = 1061 # 1061
    RNGP_PARENTREF_NO_NAME = 1062 # 1062
    RNGP_PARENTREF_NO_PARENT = 1063 # 1063
    RNGP_PARENTREF_NOT_EMPTY = 1064 # 1064
    RNGP_PARSE_ERROR = 1065 # 1065
    RNGP_PAT_ANYNAME_EXCEPT_ANYNAME = 1066 # 1066
    RNGP_PAT_ATTR_ATTR = 1067 # 1067
    RNGP_PAT_ATTR_ELEM = 1068 # 1068
    RNGP_PAT_DATA_EXCEPT_ATTR = 1069 # 1069
    RNGP_PAT_DATA_EXCEPT_ELEM = 1070 # 1070
    RNGP_PAT_DATA_EXCEPT_EMPTY = 1071 # 1071
    RNGP_PAT_DATA_EXCEPT_GROUP = 1072 # 1072
    RNGP_PAT_DATA_EXCEPT_INTERLEAVE = 1073 # 1073
    RNGP_PAT_DATA_EXCEPT_LIST = 1074 # 1074
    RNGP_PAT_DATA_EXCEPT_ONEMORE = 1075 # 1075
    RNGP_PAT_DATA_EXCEPT_REF = 1076 # 1076
    RNGP_PAT_DATA_EXCEPT_TEXT = 1077 # 1077
    RNGP_PAT_LIST_ATTR = 1078 # 1078
    RNGP_PAT_LIST_ELEM = 1079 # 1079
    RNGP_PAT_LIST_INTERLEAVE = 1080 # 1080
    RNGP_PAT_LIST_LIST = 1081 # 1081
    RNGP_PAT_LIST_REF = 1082 # 1082
    RNGP_PAT_LIST_TEXT = 1083 # 1083
    RNGP_PAT_NSNAME_EXCEPT_ANYNAME = 1084 # 1084
    RNGP_PAT_NSNAME_EXCEPT_NSNAME = 1085 # 1085
    RNGP_PAT_ONEMORE_GROUP_ATTR = 1086 # 1086
    RNGP_PAT_ONEMORE_INTERLEAVE_ATTR = 1087 # 1087
    RNGP_PAT_START_ATTR = 1088 # 1088
    RNGP_PAT_START_DATA = 1089 # 1089
    RNGP_PAT_START_EMPTY = 1090 # 1090
    RNGP_PAT_START_GROUP = 1091 # 1091
    RNGP_PAT_START_INTERLEAVE = 1092 # 1092
    RNGP_PAT_START_LIST = 1093 # 1093
    RNGP_PAT_START_ONEMORE = 1094 # 1094
    RNGP_PAT_START_TEXT = 1095 # 1095
    RNGP_PAT_START_VALUE = 1096 # 1096
    RNGP_PREFIX_UNDEFINED = 1097 # 1097
    RNGP_REF_CREATE_FAILED = 1098 # 1098
    RNGP_REF_CYCLE = 1099 # 1099
    RNGP_REF_NAME_INVALID = 1100 # 1100
    RNGP_REF_NO_DEF = 1101 # 1101
    RNGP_REF_NO_NAME = 1102 # 1102
    RNGP_REF_NOT_EMPTY = 1103 # 1103
    RNGP_START_CHOICE_AND_INTERLEAVE = 1104 # 1104
    RNGP_START_CONTENT = 1105 # 1105
    RNGP_START_EMPTY = 1106 # 1106
    RNGP_START_MISSING = 1107 # 1107
    RNGP_TEXT_EXPECTED = 1108 # 1108
    RNGP_TEXT_HAS_CHILD = 1109 # 1109
    RNGP_TYPE_MISSING = 1110 # 1110
    RNGP_TYPE_NOT_FOUND = 1111 # 1111
    RNGP_TYPE_VALUE = 1112 # 1112
    RNGP_UNKNOWN_ATTRIBUTE = 1113 # 1113
    RNGP_UNKNOWN_COMBINE = 1114 # 1114
    RNGP_UNKNOWN_CONSTRUCT = 1115 # 1115
    RNGP_UNKNOWN_TYPE_LIB = 1116 # 1116
    RNGP_URI_FRAGMENT = 1117 # 1117
    RNGP_URI_NOT_ABSOLUTE = 1118 # 1118
    RNGP_VALUE_EMPTY = 1119 # 1119
    RNGP_VALUE_NO_CONTENT = 1120 # 1120
    RNGP_XMLNS_NAME = 1121 # 1121
    RNGP_XML_NS = 1122 # 1122
    XPATH_EXPRESSION_OK = 1200
    XPATH_NUMBER_ERROR = 1201 # 1201
    XPATH_UNFINISHED_LITERAL_ERROR = 1202 # 1202
    XPATH_START_LITERAL_ERROR = 1203 # 1203
    XPATH_VARIABLE_REF_ERROR = 1204 # 1204
    XPATH_UNDEF_VARIABLE_ERROR = 1205 # 1205
    XPATH_INVALID_PREDICATE_ERROR = 1206 # 1206
    XPATH_EXPR_ERROR = 1207 # 1207
    XPATH_UNCLOSED_ERROR = 1208 # 1208
    XPATH_UNKNOWN_FUNC_ERROR = 1209 # 1209
    XPATH_INVALID_OPERAND = 1210 # 1210
    XPATH_INVALID_TYPE = 1211 # 1211
    XPATH_INVALID_ARITY = 1212 # 1212
    XPATH_INVALID_CTXT_SIZE = 1213 # 1213
    XPATH_INVALID_CTXT_POSITION = 1214 # 1214
    XPATH_MEMORY_ERROR = 1215 # 1215
    XPTR_SYNTAX_ERROR = 1216 # 1216
    XPTR_RESOURCE_ERROR = 1217 # 1217
    XPTR_SUB_RESOURCE_ERROR = 1218 # 1218
    XPATH_UNDEF_PREFIX_ERROR = 1219 # 1219
    XPATH_ENCODING_ERROR = 1220 # 1220
    XPATH_INVALID_CHAR_ERROR = 1221 # 1221
    TREE_INVALID_HEX = 1300
    TREE_INVALID_DEC = 1301 # 1301
    TREE_UNTERMINATED_ENTITY = 1302 # 1302
    SAVE_NOT_UTF8 = 1400
    SAVE_CHAR_INVALID = 1401 # 1401
    SAVE_NO_DOCTYPE = 1402 # 1402
    SAVE_UNKNOWN_ENCODING = 1403 # 1403
    REGEXP_COMPILE_ERROR = 1450
    IO_UNKNOWN = 1500
    IO_EACCES = 1501 # 1501
    IO_EAGAIN = 1502 # 1502
    IO_EBADF = 1503 # 1503
    IO_EBADMSG = 1504 # 1504
    IO_EBUSY = 1505 # 1505
    IO_ECANCELED = 1506 # 1506
    IO_ECHILD = 1507 # 1507
    IO_EDEADLK = 1508 # 1508
    IO_EDOM = 1509 # 1509
    IO_EEXIST = 1510 # 1510
    IO_EFAULT = 1511 # 1511
    IO_EFBIG = 1512 # 1512
    IO_EINPROGRESS = 1513 # 1513
    IO_EINTR = 1514 # 1514
    IO_EINVAL = 1515 # 1515
    IO_EIO = 1516 # 1516
    IO_EISDIR = 1517 # 1517
    IO_EMFILE = 1518 # 1518
    IO_EMLINK = 1519 # 1519
    IO_EMSGSIZE = 1520 # 1520
    IO_ENAMETOOLONG = 1521 # 1521
    IO_ENFILE = 1522 # 1522
    IO_ENODEV = 1523 # 1523
    IO_ENOENT = 1524 # 1524
    IO_ENOEXEC = 1525 # 1525
    IO_ENOLCK = 1526 # 1526
    IO_ENOMEM = 1527 # 1527
    IO_ENOSPC = 1528 # 1528
    IO_ENOSYS = 1529 # 1529
    IO_ENOTDIR = 1530 # 1530
    IO_ENOTEMPTY = 1531 # 1531
    IO_ENOTSUP = 1532 # 1532
    IO_ENOTTY = 1533 # 1533
    IO_ENXIO = 1534 # 1534
    IO_EPERM = 1535 # 1535
    IO_EPIPE = 1536 # 1536
    IO_ERANGE = 1537 # 1537
    IO_EROFS = 1538 # 1538
    IO_ESPIPE = 1539 # 1539
    IO_ESRCH = 1540 # 1540
    IO_ETIMEDOUT = 1541 # 1541
    IO_EXDEV = 1542 # 1542
    IO_NETWORK_ATTEMPT = 1543 # 1543
    IO_ENCODER = 1544 # 1544
    IO_FLUSH = 1545 # 1545
    IO_WRITE = 1546 # 1546
    IO_NO_INPUT = 1547 # 1547
    IO_BUFFER_FULL = 1548 # 1548
    IO_LOAD_ERROR = 1549 # 1549
    IO_ENOTSOCK = 1550 # 1550
    IO_EISCONN = 1551 # 1551
    IO_ECONNREFUSED = 1552 # 1552
    IO_ENETUNREACH = 1553 # 1553
    IO_EADDRINUSE = 1554 # 1554
    IO_EALREADY = 1555 # 1555
    IO_EAFNOSUPPORT = 1556 # 1556
    XINCLUDE_RECURSION = 1600
    XINCLUDE_PARSE_VALUE = 1601 # 1601
    XINCLUDE_ENTITY_DEF_MISMATCH = 1602 # 1602
    XINCLUDE_NO_HREF = 1603 # 1603
    XINCLUDE_NO_FALLBACK = 1604 # 1604
    XINCLUDE_HREF_URI = 1605 # 1605
    XINCLUDE_TEXT_FRAGMENT = 1606 # 1606
    XINCLUDE_TEXT_DOCUMENT = 1607 # 1607
    XINCLUDE_INVALID_CHAR = 1608 # 1608
    XINCLUDE_BUILD_FAILED = 1609 # 1609
    XINCLUDE_UNKNOWN_ENCODING = 1610 # 1610
    XINCLUDE_MULTIPLE_ROOT = 1611 # 1611
    XINCLUDE_XPTR_FAILED = 1612 # 1612
    XINCLUDE_XPTR_RESULT = 1613 # 1613
    XINCLUDE_INCLUDE_IN_INCLUDE = 1614 # 1614
    XINCLUDE_FALLBACKS_IN_INCLUDE = 1615 # 1615
    XINCLUDE_FALLBACK_NOT_IN_INCLUDE = 1616 # 1616
    XINCLUDE_DEPRECATED_NS = 1617 # 1617
    XINCLUDE_FRAGMENT_ID = 1618 # 1618
    CATALOG_MISSING_ATTR = 1650
    CATALOG_ENTRY_BROKEN = 1651 # 1651
    CATALOG_PREFER_VALUE = 1652 # 1652
    CATALOG_NOT_CATALOG = 1653 # 1653
    CATALOG_RECURSION = 1654 # 1654
    SCHEMAP_PREFIX_UNDEFINED = 1700
    SCHEMAP_ATTRFORMDEFAULT_VALUE = 1701 # 1701
    SCHEMAP_ATTRGRP_NONAME_NOREF = 1702 # 1702
    SCHEMAP_ATTR_NONAME_NOREF = 1703 # 1703
    SCHEMAP_COMPLEXTYPE_NONAME_NOREF = 1704 # 1704
    SCHEMAP_ELEMFORMDEFAULT_VALUE = 1705 # 1705
    SCHEMAP_ELEM_NONAME_NOREF = 1706 # 1706
    SCHEMAP_EXTENSION_NO_BASE = 1707 # 1707
    SCHEMAP_FACET_NO_VALUE = 1708 # 1708
    SCHEMAP_FAILED_BUILD_IMPORT = 1709 # 1709
    SCHEMAP_GROUP_NONAME_NOREF = 1710 # 1710
    SCHEMAP_IMPORT_NAMESPACE_NOT_URI = 1711 # 1711
    SCHEMAP_IMPORT_REDEFINE_NSNAME = 1712 # 1712
    SCHEMAP_IMPORT_SCHEMA_NOT_URI = 1713 # 1713
    SCHEMAP_INVALID_BOOLEAN = 1714 # 1714
    SCHEMAP_INVALID_ENUM = 1715 # 1715
    SCHEMAP_INVALID_FACET = 1716 # 1716
    SCHEMAP_INVALID_FACET_VALUE = 1717 # 1717
    SCHEMAP_INVALID_MAXOCCURS = 1718 # 1718
    SCHEMAP_INVALID_MINOCCURS = 1719 # 1719
    SCHEMAP_INVALID_REF_AND_SUBTYPE = 1720 # 1720
    SCHEMAP_INVALID_WHITE_SPACE = 1721 # 1721
    SCHEMAP_NOATTR_NOREF = 1722 # 1722
    SCHEMAP_NOTATION_NO_NAME = 1723 # 1723
    SCHEMAP_NOTYPE_NOREF = 1724 # 1724
    SCHEMAP_REF_AND_SUBTYPE = 1725 # 1725
    SCHEMAP_RESTRICTION_NONAME_NOREF = 1726 # 1726
    SCHEMAP_SIMPLETYPE_NONAME = 1727 # 1727
    SCHEMAP_TYPE_AND_SUBTYPE = 1728 # 1728
    SCHEMAP_UNKNOWN_ALL_CHILD = 1729 # 1729
    SCHEMAP_UNKNOWN_ANYATTRIBUTE_CHILD = 1730 # 1730
    SCHEMAP_UNKNOWN_ATTR_CHILD = 1731 # 1731
    SCHEMAP_UNKNOWN_ATTRGRP_CHILD = 1732 # 1732
    SCHEMAP_UNKNOWN_ATTRIBUTE_GROUP = 1733 # 1733
    SCHEMAP_UNKNOWN_BASE_TYPE = 1734 # 1734
    SCHEMAP_UNKNOWN_CHOICE_CHILD = 1735 # 1735
    SCHEMAP_UNKNOWN_COMPLEXCONTENT_CHILD = 1736 # 1736
    SCHEMAP_UNKNOWN_COMPLEXTYPE_CHILD = 1737 # 1737
    SCHEMAP_UNKNOWN_ELEM_CHILD = 1738 # 1738
    SCHEMAP_UNKNOWN_EXTENSION_CHILD = 1739 # 1739
    SCHEMAP_UNKNOWN_FACET_CHILD = 1740 # 1740
    SCHEMAP_UNKNOWN_FACET_TYPE = 1741 # 1741
    SCHEMAP_UNKNOWN_GROUP_CHILD = 1742 # 1742
    SCHEMAP_UNKNOWN_IMPORT_CHILD = 1743 # 1743
    SCHEMAP_UNKNOWN_LIST_CHILD = 1744 # 1744
    SCHEMAP_UNKNOWN_NOTATION_CHILD = 1745 # 1745
    SCHEMAP_UNKNOWN_PROCESSCONTENT_CHILD = 1746 # 1746
    SCHEMAP_UNKNOWN_REF = 1747 # 1747
    SCHEMAP_UNKNOWN_RESTRICTION_CHILD = 1748 # 1748
    SCHEMAP_UNKNOWN_SCHEMAS_CHILD = 1749 # 1749
    SCHEMAP_UNKNOWN_SEQUENCE_CHILD = 1750 # 1750
    SCHEMAP_UNKNOWN_SIMPLECONTENT_CHILD = 1751 # 1751
    SCHEMAP_UNKNOWN_SIMPLETYPE_CHILD = 1752 # 1752
    SCHEMAP_UNKNOWN_TYPE = 1753 # 1753
    SCHEMAP_UNKNOWN_UNION_CHILD = 1754 # 1754
    SCHEMAP_ELEM_DEFAULT_FIXED = 1755 # 1755
    SCHEMAP_REGEXP_INVALID = 1756 # 1756
    SCHEMAP_FAILED_LOAD = 1757 # 1757
    SCHEMAP_NOTHING_TO_PARSE = 1758 # 1758
    SCHEMAP_NOROOT = 1759 # 1759
    SCHEMAP_REDEFINED_GROUP = 1760 # 1760
    SCHEMAP_REDEFINED_TYPE = 1761 # 1761
    SCHEMAP_REDEFINED_ELEMENT = 1762 # 1762
    SCHEMAP_REDEFINED_ATTRGROUP = 1763 # 1763
    SCHEMAP_REDEFINED_ATTR = 1764 # 1764
    SCHEMAP_REDEFINED_NOTATION = 1765 # 1765
    SCHEMAP_FAILED_PARSE = 1766 # 1766
    SCHEMAP_UNKNOWN_PREFIX = 1767 # 1767
    SCHEMAP_DEF_AND_PREFIX = 1768 # 1768
    SCHEMAP_UNKNOWN_INCLUDE_CHILD = 1769 # 1769
    SCHEMAP_INCLUDE_SCHEMA_NOT_URI = 1770 # 1770
    SCHEMAP_INCLUDE_SCHEMA_NO_URI = 1771 # 1771
    SCHEMAP_NOT_SCHEMA = 1772 # 1772
    SCHEMAP_UNKNOWN_MEMBER_TYPE = 1773 # 1773
    SCHEMAP_INVALID_ATTR_USE = 1774 # 1774
    SCHEMAP_RECURSIVE = 1775 # 1775
    SCHEMAP_SUPERNUMEROUS_LIST_ITEM_TYPE = 1776 # 1776
    SCHEMAP_INVALID_ATTR_COMBINATION = 1777 # 1777
    SCHEMAP_INVALID_ATTR_INLINE_COMBINATION = 1778 # 1778
    SCHEMAP_MISSING_SIMPLETYPE_CHILD = 1779 # 1779
    SCHEMAP_INVALID_ATTR_NAME = 1780 # 1780
    SCHEMAP_REF_AND_CONTENT = 1781 # 1781
    SCHEMAP_CT_PROPS_CORRECT_1 = 1782 # 1782
    SCHEMAP_CT_PROPS_CORRECT_2 = 1783 # 1783
    SCHEMAP_CT_PROPS_CORRECT_3 = 1784 # 1784
    SCHEMAP_CT_PROPS_CORRECT_4 = 1785 # 1785
    SCHEMAP_CT_PROPS_CORRECT_5 = 1786 # 1786
    SCHEMAP_DERIVATION_OK_RESTRICTION_1 = 1787 # 1787
    SCHEMAP_DERIVATION_OK_RESTRICTION_2_1_1 = 1788 # 1788
    SCHEMAP_DERIVATION_OK_RESTRICTION_2_1_2 = 1789 # 1789
    SCHEMAP_DERIVATION_OK_RESTRICTION_2_2 = 1790 # 1790
    SCHEMAP_DERIVATION_OK_RESTRICTION_3 = 1791 # 1791
    SCHEMAP_WILDCARD_INVALID_NS_MEMBER = 1792 # 1792
    SCHEMAP_INTERSECTION_NOT_EXPRESSIBLE = 1793 # 1793
    SCHEMAP_UNION_NOT_EXPRESSIBLE = 1794 # 1794
    SCHEMAP_SRC_IMPORT_3_1 = 1795 # 1795
    SCHEMAP_SRC_IMPORT_3_2 = 1796 # 1796
    SCHEMAP_DERIVATION_OK_RESTRICTION_4_1 = 1797 # 1797
    SCHEMAP_DERIVATION_OK_RESTRICTION_4_2 = 1798 # 1798
    SCHEMAP_DERIVATION_OK_RESTRICTION_4_3 = 1799 # 1799
    SCHEMAP_COS_CT_EXTENDS_1_3 = 1800 # 1800
    SCHEMAV_NOROOT = 1801
    SCHEMAV_UNDECLAREDELEM = 1802 # 1802
    SCHEMAV_NOTTOPLEVEL = 1803 # 1803
    SCHEMAV_MISSING = 1804 # 1804
    SCHEMAV_WRONGELEM = 1805 # 1805
    SCHEMAV_NOTYPE = 1806 # 1806
    SCHEMAV_NOROLLBACK = 1807 # 1807
    SCHEMAV_ISABSTRACT = 1808 # 1808
    SCHEMAV_NOTEMPTY = 1809 # 1809
    SCHEMAV_ELEMCONT = 1810 # 1810
    SCHEMAV_HAVEDEFAULT = 1811 # 1811
    SCHEMAV_NOTNILLABLE = 1812 # 1812
    SCHEMAV_EXTRACONTENT = 1813 # 1813
    SCHEMAV_INVALIDATTR = 1814 # 1814
    SCHEMAV_INVALIDELEM = 1815 # 1815
    SCHEMAV_NOTDETERMINIST = 1816 # 1816
    SCHEMAV_CONSTRUCT = 1817 # 1817
    SCHEMAV_INTERNAL = 1818 # 1818
    SCHEMAV_NOTSIMPLE = 1819 # 1819
    SCHEMAV_ATTRUNKNOWN = 1820 # 1820
    SCHEMAV_ATTRINVALID = 1821 # 1821
    SCHEMAV_VALUE = 1822 # 1822
    SCHEMAV_FACET = 1823 # 1823
    SCHEMAV_CVC_DATATYPE_VALID_1_2_1 = 1824 # 1824
    SCHEMAV_CVC_DATATYPE_VALID_1_2_2 = 1825 # 1825
    SCHEMAV_CVC_DATATYPE_VALID_1_2_3 = 1826 # 1826
    SCHEMAV_CVC_TYPE_3_1_1 = 1827 # 1827
    SCHEMAV_CVC_TYPE_3_1_2 = 1828 # 1828
    SCHEMAV_CVC_FACET_VALID = 1829 # 1829
    SCHEMAV_CVC_LENGTH_VALID = 1830 # 1830
    SCHEMAV_CVC_MINLENGTH_VALID = 1831 # 1831
    SCHEMAV_CVC_MAXLENGTH_VALID = 1832 # 1832
    SCHEMAV_CVC_MININCLUSIVE_VALID = 1833 # 1833
    SCHEMAV_CVC_MAXINCLUSIVE_VALID = 1834 # 1834
    SCHEMAV_CVC_MINEXCLUSIVE_VALID = 1835 # 1835
    SCHEMAV_CVC_MAXEXCLUSIVE_VALID = 1836 # 1836
    SCHEMAV_CVC_TOTALDIGITS_VALID = 1837 # 1837
    SCHEMAV_CVC_FRACTIONDIGITS_VALID = 1838 # 1838
    SCHEMAV_CVC_PATTERN_VALID = 1839 # 1839
    SCHEMAV_CVC_ENUMERATION_VALID = 1840 # 1840
    SCHEMAV_CVC_COMPLEX_TYPE_2_1 = 1841 # 1841
    SCHEMAV_CVC_COMPLEX_TYPE_2_2 = 1842 # 1842
    SCHEMAV_CVC_COMPLEX_TYPE_2_3 = 1843 # 1843
    SCHEMAV_CVC_COMPLEX_TYPE_2_4 = 1844 # 1844
    SCHEMAV_CVC_ELT_1 = 1845 # 1845
    SCHEMAV_CVC_ELT_2 = 1846 # 1846
    SCHEMAV_CVC_ELT_3_1 = 1847 # 1847
    SCHEMAV_CVC_ELT_3_2_1 = 1848 # 1848
    SCHEMAV_CVC_ELT_3_2_2 = 1849 # 1849
    SCHEMAV_CVC_ELT_4_1 = 1850 # 1850
    SCHEMAV_CVC_ELT_4_2 = 1851 # 1851
    SCHEMAV_CVC_ELT_4_3 = 1852 # 1852
    SCHEMAV_CVC_ELT_5_1_1 = 1853 # 1853
    SCHEMAV_CVC_ELT_5_1_2 = 1854 # 1854
    SCHEMAV_CVC_ELT_5_2_1 = 1855 # 1855
    SCHEMAV_CVC_ELT_5_2_2_1 = 1856 # 1856
    SCHEMAV_CVC_ELT_5_2_2_2_1 = 1857 # 1857
    SCHEMAV_CVC_ELT_5_2_2_2_2 = 1858 # 1858
    SCHEMAV_CVC_ELT_6 = 1859 # 1859
    SCHEMAV_CVC_ELT_7 = 1860 # 1860
    SCHEMAV_CVC_ATTRIBUTE_1 = 1861 # 1861
    SCHEMAV_CVC_ATTRIBUTE_2 = 1862 # 1862
    SCHEMAV_CVC_ATTRIBUTE_3 = 1863 # 1863
    SCHEMAV_CVC_ATTRIBUTE_4 = 1864 # 1864
    SCHEMAV_CVC_COMPLEX_TYPE_3_1 = 1865 # 1865
    SCHEMAV_CVC_COMPLEX_TYPE_3_2_1 = 1866 # 1866
    SCHEMAV_CVC_COMPLEX_TYPE_3_2_2 = 1867 # 1867
    SCHEMAV_CVC_COMPLEX_TYPE_4 = 1868 # 1868
    SCHEMAV_CVC_COMPLEX_TYPE_5_1 = 1869 # 1869
    SCHEMAV_CVC_COMPLEX_TYPE_5_2 = 1870 # 1870
    SCHEMAV_ELEMENT_CONTENT = 1871 # 1871
    SCHEMAV_DOCUMENT_ELEMENT_MISSING = 1872 # 1872
    SCHEMAV_CVC_COMPLEX_TYPE_1 = 1873 # 1873
    SCHEMAV_CVC_AU = 1874 # 1874
    SCHEMAV_CVC_TYPE_1 = 1875 # 1875
    SCHEMAV_CVC_TYPE_2 = 1876 # 1876
    XPTR_UNKNOWN_SCHEME = 1900
    XPTR_CHILDSEQ_START = 1901 # 1901
    XPTR_EVAL_FAILED = 1902 # 1902
    XPTR_EXTRA_OBJECTS = 1903 # 1903
    C14N_CREATE_CTXT = 1950
    C14N_REQUIRES_UTF8 = 1951 # 1951
    C14N_CREATE_STACK = 1952 # 1952
    C14N_INVALID_NODE = 1953 # 1953
    FTP_PASV_ANSWER = 2000
    FTP_EPSV_ANSWER = 2001 # 2001
    FTP_ACCNT = 2002 # 2002
    HTTP_URL_SYNTAX = 2020
    HTTP_USE_IP = 2021 # 2021
    HTTP_UNKNOWN_HOST = 2022 # 2022
    SCHEMAP_SRC_SIMPLE_TYPE_1 = 3000
    SCHEMAP_SRC_SIMPLE_TYPE_2 = 3001 # 3001
    SCHEMAP_SRC_SIMPLE_TYPE_3 = 3002 # 3002
    SCHEMAP_SRC_SIMPLE_TYPE_4 = 3003 # 3003
    SCHEMAP_SRC_RESOLVE = 3004 # 3004
    SCHEMAP_SRC_RESTRICTION_BASE_OR_SIMPLETYPE = 3005 # 3005
    SCHEMAP_SRC_LIST_ITEMTYPE_OR_SIMPLETYPE = 3006 # 3006
    SCHEMAP_SRC_UNION_MEMBERTYPES_OR_SIMPLETYPES = 3007 # 3007
    SCHEMAP_ST_PROPS_CORRECT_1 = 3008 # 3008
    SCHEMAP_ST_PROPS_CORRECT_2 = 3009 # 3009
    SCHEMAP_ST_PROPS_CORRECT_3 = 3010 # 3010
    SCHEMAP_COS_ST_RESTRICTS_1_1 = 3011 # 3011
    SCHEMAP_COS_ST_RESTRICTS_1_2 = 3012 # 3012
    SCHEMAP_COS_ST_RESTRICTS_1_3_1 = 3013 # 3013
    SCHEMAP_COS_ST_RESTRICTS_1_3_2 = 3014 # 3014
    SCHEMAP_COS_ST_RESTRICTS_2_1 = 3015 # 3015
    SCHEMAP_COS_ST_RESTRICTS_2_3_1_1 = 3016 # 3016
    SCHEMAP_COS_ST_RESTRICTS_2_3_1_2 = 3017 # 3017
    SCHEMAP_COS_ST_RESTRICTS_2_3_2_1 = 3018 # 3018
    SCHEMAP_COS_ST_RESTRICTS_2_3_2_2 = 3019 # 3019
    SCHEMAP_COS_ST_RESTRICTS_2_3_2_3 = 3020 # 3020
    SCHEMAP_COS_ST_RESTRICTS_2_3_2_4 = 3021 # 3021
    SCHEMAP_COS_ST_RESTRICTS_2_3_2_5 = 3022 # 3022
    SCHEMAP_COS_ST_RESTRICTS_3_1 = 3023 # 3023
    SCHEMAP_COS_ST_RESTRICTS_3_3_1 = 3024 # 3024
    SCHEMAP_COS_ST_RESTRICTS_3_3_1_2 = 3025 # 3025
    SCHEMAP_COS_ST_RESTRICTS_3_3_2_2 = 3026 # 3026
    SCHEMAP_COS_ST_RESTRICTS_3_3_2_1 = 3027 # 3027
    SCHEMAP_COS_ST_RESTRICTS_3_3_2_3 = 3028 # 3028
    SCHEMAP_COS_ST_RESTRICTS_3_3_2_4 = 3029 # 3029
    SCHEMAP_COS_ST_RESTRICTS_3_3_2_5 = 3030 # 3030
    SCHEMAP_COS_ST_DERIVED_OK_2_1 = 3031 # 3031
    SCHEMAP_COS_ST_DERIVED_OK_2_2 = 3032 # 3032
    SCHEMAP_S4S_ELEM_NOT_ALLOWED = 3033 # 3033
    SCHEMAP_S4S_ELEM_MISSING = 3034 # 3034
    SCHEMAP_S4S_ATTR_NOT_ALLOWED = 3035 # 3035
    SCHEMAP_S4S_ATTR_MISSING = 3036 # 3036
    SCHEMAP_S4S_ATTR_INVALID_VALUE = 3037 # 3037
    SCHEMAP_SRC_ELEMENT_1 = 3038 # 3038
    SCHEMAP_SRC_ELEMENT_2_1 = 3039 # 3039
    SCHEMAP_SRC_ELEMENT_2_2 = 3040 # 3040
    SCHEMAP_SRC_ELEMENT_3 = 3041 # 3041
    SCHEMAP_P_PROPS_CORRECT_1 = 3042 # 3042
    SCHEMAP_P_PROPS_CORRECT_2_1 = 3043 # 3043
    SCHEMAP_P_PROPS_CORRECT_2_2 = 3044 # 3044
    SCHEMAP_E_PROPS_CORRECT_2 = 3045 # 3045
    SCHEMAP_E_PROPS_CORRECT_3 = 3046 # 3046
    SCHEMAP_E_PROPS_CORRECT_4 = 3047 # 3047
    SCHEMAP_E_PROPS_CORRECT_5 = 3048 # 3048
    SCHEMAP_E_PROPS_CORRECT_6 = 3049 # 3049
    SCHEMAP_SRC_INCLUDE = 3050 # 3050
    SCHEMAP_SRC_ATTRIBUTE_1 = 3051 # 3051
    SCHEMAP_SRC_ATTRIBUTE_2 = 3052 # 3052
    SCHEMAP_SRC_ATTRIBUTE_3_1 = 3053 # 3053
    SCHEMAP_SRC_ATTRIBUTE_3_2 = 3054 # 3054
    SCHEMAP_SRC_ATTRIBUTE_4 = 3055 # 3055
    SCHEMAP_NO_XMLNS = 3056 # 3056
    SCHEMAP_NO_XSI = 3057 # 3057
    SCHEMAP_COS_VALID_DEFAULT_1 = 3058 # 3058
    SCHEMAP_COS_VALID_DEFAULT_2_1 = 3059 # 3059
    SCHEMAP_COS_VALID_DEFAULT_2_2_1 = 3060 # 3060
    SCHEMAP_COS_VALID_DEFAULT_2_2_2 = 3061 # 3061
    SCHEMAP_CVC_SIMPLE_TYPE = 3062 # 3062
    SCHEMAP_COS_CT_EXTENDS_1_1 = 3063 # 3063
    SCHEMAP_SRC_IMPORT_1_1 = 3064 # 3064
    SCHEMAP_SRC_IMPORT_1_2 = 3065 # 3065
    SCHEMAP_SRC_IMPORT_2 = 3066 # 3066
    SCHEMAP_SRC_IMPORT_2_1 = 3067 # 3067
    SCHEMAP_SRC_IMPORT_2_2 = 3068 # 3068
    SCHEMAP_INTERNAL = 3069 # 3069 non-W3C
    SCHEMAP_NOT_DETERMINISTIC = 3070 # 3070 non-W3C
    SCHEMAP_SRC_ATTRIBUTE_GROUP_1 = 3071 # 3071
    SCHEMAP_SRC_ATTRIBUTE_GROUP_2 = 3072 # 3072
    SCHEMAP_SRC_ATTRIBUTE_GROUP_3 = 3073 # 3073
    SCHEMAP_MG_PROPS_CORRECT_1 = 3074 # 3074
    SCHEMAP_MG_PROPS_CORRECT_2 = 3075 # 3075
    SCHEMAP_SRC_CT_1 = 3076 # 3076
    SCHEMAP_DERIVATION_OK_RESTRICTION_2_1_3 = 3077 # 3077
    SCHEMAP_AU_PROPS_CORRECT_2 = 3078 # 3078
    SCHEMAP_A_PROPS_CORRECT_2 = 3079 # 3079
    MODULE_OPEN = 4900 # 4900
    MODULE_CLOSE = 4901 # 4901
    CHECK_FOUND_ELEMENT = 5000
    CHECK_FOUND_ATTRIBUTE = 5001 # 5001
    CHECK_FOUND_TEXT = 5002 # 5002
    CHECK_FOUND_CDATA = 5003 # 5003
    CHECK_FOUND_ENTITYREF = 5004 # 5004
    CHECK_FOUND_ENTITY = 5005 # 5005
    CHECK_FOUND_PI = 5006 # 5006
    CHECK_FOUND_COMMENT = 5007 # 5007
    CHECK_FOUND_DOCTYPE = 5008 # 5008
    CHECK_FOUND_FRAGMENT = 5009 # 5009
    CHECK_FOUND_NOTATION = 5010 # 5010
    CHECK_UNKNOWN_NODE = 5011 # 5011
    CHECK_ENTITY_TYPE = 5012 # 5012
    CHECK_NO_PARENT = 5013 # 5013
    CHECK_NO_DOC = 5014 # 5014
    CHECK_NO_NAME = 5015 # 5015
    CHECK_NO_ELEM = 5016 # 5016
    CHECK_WRONG_DOC = 5017 # 5017
    CHECK_NO_PREV = 5018 # 5018
    CHECK_WRONG_PREV = 5019 # 5019
    CHECK_NO_NEXT = 5020 # 5020
    CHECK_WRONG_NEXT = 5021 # 5021
    CHECK_NOT_DTD = 5022 # 5022
    CHECK_NOT_ATTR = 5023 # 5023
    CHECK_NOT_ATTR_DECL = 5024 # 5024
    CHECK_NOT_ELEM_DECL = 5025 # 5025
    CHECK_NOT_ENTITY_DECL = 5026 # 5026
    CHECK_NOT_NS_DECL = 5027 # 5027
    CHECK_NO_HREF = 5028 # 5028
    CHECK_WRONG_PARENT = 5029 # 5029
    CHECK_NS_SCOPE = 5030 # 5030
    CHECK_NS_ANCESTOR = 5031 # 5031
    CHECK_NOT_UTF8 = 5032 # 5032
    CHECK_NO_DICT = 5033 # 5033
    CHECK_NOT_NCNAME = 5034 # 5034
    CHECK_OUTSIDE_DICT = 5035 # 5035
    CHECK_WRONG_NAME = 5036 # 5036
    CHECK_NAME_NOT_NULL = 5037 # 5037
    CHECK_ = 5038 # 5033
    CHECK_X = 5039 # 503

cdef object __names
__names = ErrorLevels._names
for name, value in vars(ErrorLevels).iteritems():
    python.PyDict_SetItem(__names, value, name)

__names = ErrorDomains._names
for name, value in vars(ErrorDomains).iteritems():
    python.PyDict_SetItem(__names, value, name)

__names = ErrorTypes._names
for name, value in vars(ErrorTypes).iteritems():
    python.PyDict_SetItem(__names, value, name)
