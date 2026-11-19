// Winsock 1.1 stubs (WSOCK32.dll ordinal imports). Skyrim imports networking symbols
// (likely crash-reporting / unused Bethesda net code); failing socket creation cleanly keeps
// the game on its offline path without hanging.
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include "shims.h"

static _Thread_local uint32_t wsa_last_error;
#define WSAENETDOWN 10050u

SHIM(WSAStartup) {
    uint32_t wsa_data = ARG(c, 1);
    if (wsa_data) {
        memset(MEM + wsa_data, 0, 400);
        uint16_t ver = (uint16_t)ARG(c, 0);
        memcpy(MEM + wsa_data, &ver, 2);
        memcpy(MEM + wsa_data + 2, &ver, 2);
    }
    wsa_last_error = 0;
    RET(c, 0, 2);
}
SHIM(WSAGetLastError) { RET(c, wsa_last_error, 0); }
SHIM(WSAAsyncSelect) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 4); }
SHIM(socket) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 3); }
SHIM(closesocket) { RET(c, 0, 1); }
SHIM(bind) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 3); }
SHIM(listen) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 2); }
SHIM(accept) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 3); }
SHIM(connect) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 3); }
SHIM(send) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 4); }
SHIM(recv) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 4); }
SHIM(select) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 5); }
SHIM(ioctlsocket) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 3); }
SHIM(setsockopt) { wsa_last_error = WSAENETDOWN; RET(c, 0xFFFFFFFFu, 5); }
SHIM(htons) { RET(c, (uint16_t)htons((uint16_t)ARG(c, 0)), 1); }
SHIM(ntohs) { RET(c, (uint16_t)ntohs((uint16_t)ARG(c, 0)), 1); }
SHIM(inet_addr) { const char *s = GSTR(ARG(c, 0)); RET(c, s ? (uint32_t)inet_addr(s) : 0xFFFFFFFFu, 1); }
SHIM(inet_ntoa) {
    struct in_addr in; in.s_addr = ARG(c, 0);
    const char *s = inet_ntoa(in);
    static uint32_t buf;
    if (!buf) buf = gmalloc(32);
    snprintf((char *)MEM + buf, 32, "%s", s ? s : "0.0.0.0");
    RET(c, buf, 1);
}
SHIM(gethostbyname) { wsa_last_error = 11001u /* WSAHOST_NOT_FOUND */; RET(c, 0, 1); }
SHIM(gethostname) {
    uint32_t p = ARG(c, 0), len = ARG(c, 1);
    const char *nm = "skyrim-mac";
    if (p && len > strlen(nm)) { strcpy((char *)MEM + p, nm); RET(c, 0, 2); }
    else { wsa_last_error = 10014u; RET(c, 0xFFFFFFFFu, 2); }
}
SHIM(__WSAFDIsSet) { RET(c, 0, 2); }

#define O(ord, fn) { "wsock32#" #ord, fn##_ },
SHIM_TABLE(wsock_shims,
    O(1, accept) O(2, bind) O(3, closesocket) O(4, connect)
    O(9, htons) O(10, inet_addr) O(11, inet_ntoa) O(12, ioctlsocket) O(13, listen)
    O(15, ntohs) O(16, recv) O(18, select) O(19, send) O(21, setsockopt) O(23, socket)
    O(52, gethostbyname) O(57, gethostname) O(101, WSAAsyncSelect)
    O(111, WSAGetLastError) O(115, WSAStartup) O(151, __WSAFDIsSet)
    E(accept) E(bind) E(closesocket) E(connect) E(htons) E(inet_addr) E(inet_ntoa)
    E(ioctlsocket) E(listen) E(ntohs) E(recv) E(select) E(send) E(setsockopt) E(socket)
    E(gethostbyname) E(gethostname) E(WSAAsyncSelect) E(WSAGetLastError) E(WSAStartup) E(__WSAFDIsSet))
