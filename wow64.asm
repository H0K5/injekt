 ;
 ;   Shell Code Injector v0.1
 ;   Copyright (C) 2014, 2015 Odzhan
 ;
 ;   This program is free software: you can redistribute it and/or modify
 ;   it under the terms of the GNU General Public License as published by
 ;   the Free Software Foundation, either version 3 of the License, or
 ;   (at your option) any later version.
 ;
 ;   This program is distributed in the hope that it will be useful,
 ;   but WITHOUT ANY WARRANTY; without even the implied warranty of
 ;   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 ;   GNU General Public License for more details.
 ;
 ;   You should have received a copy of the GNU General Public License
 ;   along with this program.  If not, see <http://www.gnu.org/licenses/>.
 ;
 
 ; 32-bit OBJ
 ;   yasm -f win32 thread.asm -o thread.obj
 ;
 ; 64-bit OBJ
 ;   yasm -f win64 thread.asm -o thread.obj

struc UNICODE_STRING
  .Length:        resw 1
  .MaximumLength: resw 1
  .Reserved       resd 1 ; this is to align by 8 bytes
  .Buffer:        resq 1
  .size:
endstruc

struc HOME_SPACE
  ._rcx resq 1
  ._rdx resq 1
  ._r8  resq 1
  ._r9  resq 1
  .size:
endstruc

struc ct_stk
  .hs: resb HOME_SPACE.size
  
  .lpStartAddress     resq 1
  .lpParameter        resq 1
  .CreateSuspended    resq 1
  .StackZeroBits      resq 1
  .SizeOfStackCommit  resq 1
  .SizeOfStackReserve resq 1
  .lpBytesBuffer      resq 1
  
  .size:
endstruc
    
struc qi_stk
  .hs: resb HOME_SPACE.size
  
  .ReturnLength     resq 1
  .size:
endstruc

struc rm_stk
  .hs: resb HOME_SPACE.size
  
  .NumberOfBytesRead     resq 1
  .size:
endstruc

  section .bss
hThread: resq 1
ntStatus: resd 1

  section .text

%define ROL_CONSTANT 9

; http://www.asmcommunity.net/forums/topic/?id=16924
; originally by Vecna/29a, converted to NASM syntax by Jibz
%macro HASH 1.nolist
  %assign %%h 0
  %strlen %%len %1
  %assign %%i 1
  %rep %%len
    %substr %%c %1 %%i
    %assign %%h ((%%h + %%c) & 0FFFFFFFFh)
    %assign %%h ((%%h << ROL_CONSTANT) & 0FFFFFFFFh) | (%%h >> (32-ROL_CONSTANT))
    %assign %%h ((%%h ^ %%c) & 0FFFFFFFFh)
    %assign %%i (%%i+1)
  %endrep
  %assign %%h ((%%h << ROL_CONSTANT) & 0FFFFFFFFh) | (%%h >> (32-ROL_CONSTANT))
  dd %%h
%endmacro

; mov eax, HASH "string"
%macro hmov 1.nolist
  db 0B8h
  HASH %1
%endmacro

  bits 32
  ; switch to x64 mode
sw64:
    call   isWow64
    jz     ext64                 ; we're already x64
    pop    eax                   ; get return address
    push   33h                   ; x64 selector
    push   eax                   ; return address
    retf                         ; go to x64 mode
ext64:
    ret
    
  ; switch to x86 mode
sw32:
    call   isWow64
    jnz    ext32                 ; we're already x86
    pop    eax
    sub    esp, 8
    mov    dword[esp], eax
    mov    dword[esp+4], 23h     ; x86 selector
    retf
ext32:
    ret

; #################################################################
;
; return address of api based on hash
;
; #################################################################
getapi:
    bits   64
    push   rsi
    push   rdi
    push   rbx
    push   rcx
    
    mov    r8, rax
    push   60h
    pop    rsi
    mov    rax, qword [gs:rsi]
    mov    rax, [rax+18h]
    mov    r10, [rax+30h]
load_dll:
    mov    rbp, [r10+10h]
    test   rbp, rbp
    mov    eax, ebp
    jz     exit_getapi
    mov    r10, [r10]
    
    mov    eax, [rbp+3Ch]      ; IMAGE_DOS_HEADER.e_lfanew
    add    eax, 10h
    mov    eax, [rbp+rax+78h]
    lea    rsi, [rbp+rax+18h]  ; IMAGE_EXPORT_DIRECTORY.NumberOfNames
    lodsd
    xchg   eax, ecx
    jecxz  load_dll

    lodsd                   ; IMAGE_EXPORT_DIRECTORY.AddressOfFunctions
    
    ; EMET will break on the following instruction
    lea    r11, [rbp+rax]

    lodsd                   ; IMAGE_EXPORT_DIRECTORY.AddressOfNames
    lea    rdi, [rbp+rax]

    lodsd                   ; IMAGE_EXPORT_DIRECTORY.AddressOfNameOrdinals
    lea    rbx, [rbp+rax]
load_api:
    mov    esi, [rdi+4*rcx-4]
    add    rsi, rbp
    xor    eax, eax
    cdq
hash_api:
    lodsb
    add    edx, eax
    rol    edx, ROL_CONSTANT
    xor    edx, eax
    dec    eax
    jns    hash_api
    
    cmp  edx, r8d

    loopne load_api
    jne    load_dll
    
    movzx  edx, word [rbx+2*rcx]
    mov    eax, [r11+4*rdx]
    add    rax, rbp
exit_getapi:
    pop    rcx
    pop    rbx
    pop    rdi
    pop    rsi
    ret
    
; ##############################################################
  global isWow64
  global _isWow64

  ; returns TRUE or FALSE
isWow64:
_isWow64:
    bits   32
    xor    eax, eax
    dec    eax
    neg    eax
    ret
    
; ##############################################################
    global CreateRemoteThread64
    global _CreateRemoteThread64
    
CreateRemoteThread64:
_CreateRemoteThread64:
    bits   32
    push   ebx
    push   esi
    push   edi
    push   ebp
    
    call   sw64                  ; switch to x64 mode
    test   eax, eax              ; we're already in x64 mode and will only work with wow64 process, return 0
    jz     exit_create
    
    bits   64
    mov    rsi, rsp
    and    rsp, -16
    sub    rsp, ((ct_stk.size & -16) + 16) - 8
    
    ; NTSTATUS NtCreateThreadEx(
    ;     OUT PHANDLE hThread,
    ;     IN ACCESS_MASK DesiredAccess,
    ;     IN LPVOID ObjectAttributes,
    ;     IN HANDLE ProcessHandle,
    ;     IN LPTHREAD_START_ROUTINE lpStartAddress,
    ;     IN LPVOID lpParameter,
    ;     IN BOOL CreateSuspended,
    ;     IN ULONG StackZeroBits,
    ;     IN ULONG SizeOfStackCommit,
    ;     IN ULONG SizeOfStackReserve,
    ;     OUT LPVOID lpBytesBuffer);
    hmov   "NtCreateThreadEx"
    call   getapi
    mov    rbx, rax
    
    ; CreateRemoteThread64 (HANDLE hProcess, 
    ;     LPSECURITY_ATTRIBUTES lpThreadAttributes, SIZE_T dwStackSize,
    ;     LPTHREAD_START_ROUTINE lpStartAddress, LPVOID lpParameter,
    ;     DWORD dwCreationFlags, LPDWORD lpThreadId
    xor    r8, r8
    xor    rax, rax
    
    mov    [rsp+ct_stk.lpBytesBuffer     ], rax ; NULL
    mov    [rsp+ct_stk.SizeOfStackReserve], rax ; NULL
    mov    [rsp+ct_stk.SizeOfStackCommit ], rax ; NULL
    mov    [rsp+ct_stk.StackZeroBits     ], rax ; NULL
    
    mov    [rsp+ct_stk.CreateSuspended   ], rax
    
    mov    eax, [rsi+9*4]        ; lpParameter
    mov    [rsp+ct_stk.lpParameter       ], rax
    
    mov    eax, [rsi+8*4]        ; lpStartAddress
    mov    [rsp+ct_stk.lpStartAddress    ], rax
    
    mov    r9d, [rsi+5*4]        ; hProcess
    mov    edx, 10000000h        ; GENERIC_ALL
    lea    rcx, [rel hThread]        ; &hThread
    call   rbx
    
    mov    rsp, rsi              ; restore stack value
    
    call   sw32                  ; switch back to x86 mode
    mov    eax, [rel hThread+0] ; return thread handle
exit_create:
    bits   32
    pop    ebp
    pop    edi
    pop    esi
    pop    ebx
    ret
    
; ##############################################################
    global NtQueryInformationProcess64
    global _NtQueryInformationProcess64
    
NtQueryInformationProcess64:
_NtQueryInformationProcess64:
    bits   32
    push   ebx
    push   esi
    push   edi
    push   ebp
    
    call   sw64                  ; switch to x64 mode
    test   eax, eax              ; we're already in x64 mode and will only work with wow64 process, return 0
    jz     exit_query
    
    bits   64
    mov    rsi, rsp
    and    rsp, -16
    sub    rsp, ((qi_stk.size & -16) + 16) - 8
    
    hmov   "NtQueryInformationProcess"
    call   getapi
    mov    rbx, rax

    mov    eax, [rsi+9*4]        ; ReturnLength
    mov    [rsp+qi_stk.ReturnLength], rax
    mov    r9d, [rsi+8*4]        ; ProcessInformationLength
    mov    r8d, [rsi+7*4]        ; ProcessInformation
    mov    edx, [rsi+6*4]        ; ProcessInformationClass
    mov    ecx, [rsi+5*4]        ; ProcessHandle
    call   rbx
    mov    [rel ntStatus], eax
    
    mov    rsp, rsi              ; restore stack value
    
    call   sw32                  ; switch back to x86 mode
exit_query:
    mov    eax, [rel ntStatus]
    bits   32
    pop    ebp
    pop    edi
    pop    esi
    pop    ebx
    ret
    
; ##############################################################    
  global NtReadVirtualMemory64
  global _NtReadVirtualMemory64

NtReadVirtualMemory64:
_NtReadVirtualMemory64:
    push   ebx
    push   esi
    push   edi
    push   ebp
    
    call   sw64                  ; switch to x64 mode
    test   eax, eax              ; will only work with wow64 process, return 0
    cdq
    jz     exit_read
    
    bits   64
    mov    rsi, rsp
    and    rsp, -16
    sub    rsp, ((qi_stk.size & -16) + 16) - 8
    
    bits   64    
    ; NTSTATUS NtReadVirtualMemory(
    ;     IN HANDLE   ProcessHandle,
    ;     IN PVOID    BaseAddress,
    ;     OUT PVOID   Buffer,
    ;     IN SIZE_T   NumberOfBytesToRead,
    ;     OUT PSIZE_T NumberOfBytesRead OPTIONAL);  
    hmov   "NtReadVirtualMemory"
    call   getapi
    mov    rbx, rax

    mov    eax, [rsi+10*4]        ; NumberOfBytesRead
    mov    [rsp+rm_stk.NumberOfBytesRead], rax
    mov    r9d, [rsi+9*4]        ; NumberOfBytesToRead
    mov    r8d, [rsi+8*4]        ; Buffer
    mov    rdx, [rsi+6*4]        ; BaseAddress
    mov    ecx, [rsi+5*4]        ; ProcessHandle
    call   rbx
    mov    [rel ntStatus], eax
    
    mov    rsp, rsi              ; restore stack value
 
    bits   32
    call   sw32                  ; switch back to x86 mode
exit_read:
    pop    ebp
    pop    edi
    pop    esi
    pop    ebx
    ret  
