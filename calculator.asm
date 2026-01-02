; GUI Calculator in x86-64 Assembly (NASM) for Linux
; Uses X11/Xlib for windowing
; Target: x86-64 Linux with NASM assembler

BITS 64
CPU X64

; System call numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_SOCKET      41
%define SYS_CONNECT     42
%define SYS_EXIT        60

; Socket constants
%define AF_UNIX         1
%define SOCK_STREAM     1

; X11 Protocol constants
%define X11_OP_CREATE_WINDOW    0x01
%define X11_OP_MAP_WINDOW       0x08
%define X11_OP_CREATE_GC        0x37
%define X11_OP_OPEN_FONT        0x2d
%define X11_OP_IMAGE_TEXT8      0x4c
%define X11_OP_POLY_RECTANGLE   0x43
%define X11_OP_POLY_FILL_RECT   0x46

; X11 Event types
%define X11_EVENT_KEY_PRESS     2
%define X11_EVENT_KEY_RELEASE   3
%define X11_EVENT_BUTTON_PRESS  4
%define X11_EVENT_EXPOSE        12

; X11 Flags
%define X11_FLAG_WIN_BG_COLOR   0x00000002
%define X11_FLAG_WIN_EVENT      0x00000800
%define X11_FLAG_GC_FG          0x00000008
%define X11_FLAG_GC_BG          0x00000004
%define X11_FLAG_GC_FONT        0x00004000

; Event masks
%define EVENT_MASK_KEY_PRESS    0x0001
%define EVENT_MASK_KEY_RELEASE  0x0002
%define EVENT_MASK_BUTTON_PRESS 0x0004
%define EVENT_MASK_EXPOSURE     0x8000

; Calculator constants
%define WINDOW_WIDTH    240
%define WINDOW_HEIGHT   320
%define BUTTON_WIDTH    55
%define BUTTON_HEIGHT   50
%define DISPLAY_HEIGHT  40

section .data
    ; X11 socket path
    sun_path: db "/tmp/.X11-unix/X0", 0
    
    ; Calculator state
    operand1:       dq 0        ; First operand
    operand2:       dq 0        ; Second operand
    result:         dq 0        ; Result
    operator:       db 0        ; Current operator: 0=none, 1=+, 2=-, 3=*, 4=/
    input_buffer:   times 16 db 0  ; Current input string
    input_len:      db 0        ; Length of input
    needs_clear:    db 0        ; Flag to clear on next digit
    
    ; X11 resource IDs
    id:             dd 1
    id_base:        dd 0
    id_mask:        dd 0
    root_visual_id: dd 0
    socket_fd:      dd 0
    window_id:      dd 0
    gc_id:          dd 0
    gc_button:      dd 0
    font_id:        dd 0
    root_id:        dd 0
    
    ; Font name
    font_name: db "fixed", 0
    font_name_len equ $ - font_name - 1
    
    ; Button labels
    btn_labels: db "789/456*123-0C=+"
    
    ; Number conversion buffer
    num_buffer: times 32 db 0

section .bss
    event_buffer: resb 32768
    
section .text
global _start

;========================================
; Entry Point
;========================================
_start:
    push rbp
    mov rbp, rsp
    
    ; Connect to X11 server
    call x11_connect
    mov [socket_fd], eax
    
    ; Send handshake
    mov edi, eax
    call x11_handshake
    mov [root_id], eax
    
    ; Initialize calculator state
    mov QWORD [operand1], 0
    mov QWORD [operand2], 0
    mov QWORD [result], 0
    mov BYTE [operator], 0
    mov BYTE [input_len], 0
    mov BYTE [input_buffer], '0'
    mov BYTE [input_len], 1
    
    ; Create resources
    call x11_create_resources
    
    ; Main event loop
    call event_loop
    
    ; Exit
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

;========================================
; X11 Connection
;========================================
x11_connect:
    push rbp
    mov rbp, rsp
    sub rsp, 112
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_UNIX
    mov rsi, SOCK_STREAM
    xor rdx, rdx
    syscall
    
    cmp rax, 0
    jle error_exit
    mov r12, rax            ; Save socket fd
    
    ; Setup sockaddr_un structure
    mov WORD [rsp], AF_UNIX
    lea rsi, [sun_path]
    lea rdi, [rsp + 2]
    mov ecx, 19
    cld
    rep movsb
    
    ; Connect
    mov rax, SYS_CONNECT
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, 110
    syscall
    
    cmp rax, 0
    jne error_exit
    
    mov rax, r12            ; Return socket fd
    add rsp, 112
    pop rbp
    ret

;========================================
; X11 Handshake
;========================================
x11_handshake:
    push rbp
    mov rbp, rsp
    sub rsp, 32768
    
    mov r12, rdi            ; Save socket fd
    
    ; Build handshake packet
    mov BYTE [rsp + 0], 'l' ; Little endian
    mov BYTE [rsp + 1], 0
    mov WORD [rsp + 2], 11  ; Major version
    mov WORD [rsp + 4], 0   ; Minor version
    mov WORD [rsp + 6], 0   ; Auth proto len
    mov WORD [rsp + 8], 0   ; Auth data len
    
    ; Send handshake
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, 12
    syscall
    
    ; Read response (8 bytes first)
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, 8
    syscall
    
    cmp BYTE [rsp], 1       ; Check success
    jne error_exit
    
    ; Read rest of response
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, 32768
    syscall
    
    ; Extract id_base and id_mask
    mov edx, DWORD [rsp + 4]
    mov [id_base], edx
    mov edx, DWORD [rsp + 8]
    mov [id_mask], edx
    
    ; Parse server data to find root window and visual
    lea rdi, [rsp]
    mov cx, WORD [rsp + 16]     ; Vendor length
    movzx rcx, cx
    movzx rax, BYTE [rsp + 21]  ; Format count
    imul rax, 8
    
    add rdi, 32
    add rdi, rcx
    add rdi, 3
    and rdi, -4                 ; Align
    add rdi, rax
    
    mov eax, DWORD [rdi]        ; Root window ID
    mov r13d, eax
    mov edx, DWORD [rdi + 32]   ; Root visual ID
    mov [root_visual_id], edx
    
    mov rax, r13
    add rsp, 32768
    pop rbp
    ret

;========================================
; Generate next X11 resource ID
;========================================
x11_next_id:
    push rbp
    mov rbp, rsp
    
    mov eax, [id]
    mov edi, [id_base]
    mov edx, [id_mask]
    
    and eax, edx
    or eax, edi
    
    add DWORD [id], 1
    
    pop rbp
    ret

;========================================
; Create X11 Resources
;========================================
x11_create_resources:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    
    mov edi, [socket_fd]
    mov r12d, edi
    
    ; Create font
    call x11_next_id
    mov [font_id], eax
    mov esi, eax
    mov edi, r12d
    call x11_open_font
    
    ; Create main GC
    call x11_next_id
    mov [gc_id], eax
    mov esi, eax
    mov edx, [root_id]
    mov ecx, [font_id]
    mov edi, r12d
    call x11_create_gc
    
    ; Create button GC
    call x11_next_id
    mov [gc_button], eax
    mov esi, eax
    mov edx, [root_id]
    mov ecx, [font_id]
    mov edi, r12d
    call x11_create_gc
    
    ; Create window
    call x11_next_id
    mov [window_id], eax
    mov esi, eax
    mov edx, [root_id]
    mov ecx, [root_visual_id]
    mov r8d, (10 << 16) | 10    ; x=10, y=10
    mov r9d, (WINDOW_HEIGHT << 16) | WINDOW_WIDTH
    mov edi, r12d
    call x11_create_window
    
    ; Map window
    mov edi, r12d
    mov esi, [window_id]
    call x11_map_window
    
    add rsp, 128
    pop rbp
    ret

;========================================
; Open Font
;========================================
x11_open_font:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    
    mov r12, rdi
    mov r13, rsi
    
    mov BYTE [rsp + 0], X11_OP_OPEN_FONT
    mov BYTE [rsp + 1], 0
    mov WORD [rsp + 2], 3 + ((font_name_len + 3) / 4)
    mov DWORD [rsp + 4], r13d
    mov WORD [rsp + 8], font_name_len
    mov WORD [rsp + 10], 0
    
    ; Copy font name
    lea rsi, [font_name]
    lea rdi, [rsp + 12]
    mov ecx, font_name_len
    rep movsb
    
    ; Write to X11
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, 12 + font_name_len
    add rdx, 3
    and rdx, -4
    syscall
    
    add rsp, 64
    pop rbp
    ret

;========================================
; Create Graphics Context
;========================================
x11_create_gc:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    
    mov BYTE [rsp + 0], X11_OP_CREATE_GC
    mov BYTE [rsp + 1], 0
    mov WORD [rsp + 2], 7       ; Packet length
    mov DWORD [rsp + 4], r13d   ; GC ID
    mov DWORD [rsp + 8], r14d   ; Drawable (root)
    mov DWORD [rsp + 12], X11_FLAG_GC_FG | X11_FLAG_GC_BG | X11_FLAG_GC_FONT
    mov DWORD [rsp + 16], 0x00000000  ; Foreground (black)
    mov DWORD [rsp + 20], 0x00FFFFFF  ; Background (white)
    mov DWORD [rsp + 24], r15d  ; Font
    
    mov rax, SYS_WRITE
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, 28
    syscall
    
    add rsp, 64
    pop rbp
    ret

;========================================
; Create Window
;========================================
x11_create_window:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    
    mov [rsp + 64], rdi
    mov [rsp + 72], rsi
    mov [rsp + 80], rdx
    mov [rsp + 88], rcx
    mov [rsp + 96], r8
    mov [rsp + 104], r9
    
    mov BYTE [rsp + 0], X11_OP_CREATE_WINDOW
    mov BYTE [rsp + 1], 24      ; Depth
    mov WORD [rsp + 2], 10      ; Packet length
    mov eax, [rsp + 72]
    mov DWORD [rsp + 4], eax    ; Window ID
    mov eax, [rsp + 80]
    mov DWORD [rsp + 8], eax    ; Parent
    mov eax, [rsp + 96]
    mov DWORD [rsp + 12], eax   ; x, y
    mov eax, [rsp + 104]
    mov DWORD [rsp + 16], eax   ; width, height
    mov WORD [rsp + 20], 1      ; Border width
    mov WORD [rsp + 22], 1      ; Class
    mov eax, [rsp + 88]
    mov DWORD [rsp + 24], eax   ; Visual
    mov DWORD [rsp + 28], X11_FLAG_WIN_BG_COLOR | X11_FLAG_WIN_EVENT
    mov DWORD [rsp + 32], 0x00FFFFFF  ; BG color (white)
    mov DWORD [rsp + 36], EVENT_MASK_KEY_PRESS | EVENT_MASK_BUTTON_PRESS | EVENT_MASK_EXPOSURE
    
    mov rax, SYS_WRITE
    mov rdi, [rsp + 64]
    lea rsi, [rsp]
    mov rdx, 40
    syscall
    
    add rsp, 128
    pop rbp
    ret

;========================================
; Map Window
;========================================
x11_map_window:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    
    mov BYTE [rsp + 0], X11_OP_MAP_WINDOW
    mov BYTE [rsp + 1], 0
    mov WORD [rsp + 2], 2
    mov DWORD [rsp + 4], esi
    
    mov rax, SYS_WRITE
    lea rsi, [rsp]
    mov rdx, 8
    syscall
    
    add rsp, 32
    pop rbp
    ret

;========================================
; Draw Text
; Parameters: rdi=x, rsi=y, rdx=text_ptr, rcx=text_len
;========================================
draw_text:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    
    mov [rsp + 64], rdi
    mov [rsp + 72], rsi
    mov [rsp + 80], rdx
    mov [rsp + 88], rcx
    
    ; Calculate packet length: 4 + (text_len + 3) / 4
    mov rax, rcx
    add rax, 3
    shr rax, 2              ; Divide by 4
    add rax, 4
    
    mov BYTE [rsp + 0], X11_OP_IMAGE_TEXT8
    mov r8b, cl
    mov BYTE [rsp + 1], r8b     ; String length
    mov WORD [rsp + 2], ax      ; Packet length
    mov eax, [window_id]
    mov DWORD [rsp + 4], eax
    mov eax, [gc_id]
    mov DWORD [rsp + 8], eax
    mov eax, [rsp + 64]
    mov WORD [rsp + 12], ax     ; x
    mov eax, [rsp + 72]
    mov WORD [rsp + 14], ax     ; y
    
    ; Copy text
    lea rdi, [rsp + 16]
    mov rsi, [rsp + 80]
    mov rcx, [rsp + 88]
    rep movsb
    
    ; Calculate write length
    mov rdx, [rsp + 88]
    add rdx, 16
    add rdx, 3
    and rdx, -4
    
    mov rax, SYS_WRITE
    mov edi, [socket_fd]
    lea rsi, [rsp]
    syscall
    
    add rsp, 128
    pop rbp
    ret

;========================================
; Draw Rectangle (outline)
;========================================
draw_rectangle:
    ; Parameters: rdi=x, rsi=y, rdx=width, rcx=height
    push rbp
    mov rbp, rsp
    sub rsp, 64
    
    mov BYTE [rsp + 0], X11_OP_POLY_RECTANGLE
    mov BYTE [rsp + 1], 0
    mov WORD [rsp + 2], 5
    mov eax, [window_id]
    mov DWORD [rsp + 4], eax
    mov eax, [gc_button]
    mov DWORD [rsp + 8], eax
    mov WORD [rsp + 12], di
    mov WORD [rsp + 14], si
    mov WORD [rsp + 16], dx
    mov WORD [rsp + 18], cx
    
    mov rax, SYS_WRITE
    mov edi, [socket_fd]
    lea rsi, [rsp]
    mov rdx, 20
    syscall
    
    add rsp, 64
    pop rbp
    ret

;========================================
; Redraw Calculator Display
;========================================
redraw_display:
    push rbp
    mov rbp, rsp
    
    ; Draw display rectangle
    mov rdi, 5
    mov rsi, 5
    mov rdx, WINDOW_WIDTH - 10
    mov rcx, DISPLAY_HEIGHT
    call draw_rectangle
    
    ; Draw current input
    mov rdi, 15
    mov rsi, 30
    lea rdx, [input_buffer]
    movzx rcx, BYTE [input_len]
    call draw_text
    
    ; Draw buttons (4x4 grid)
    xor r12, r12                ; Button index
.button_loop:
    cmp r12, 16
    jge .done
    
    ; Calculate position
    mov rax, r12
    xor rdx, rdx
    mov rcx, 4
    div rcx
    mov r13, rax                ; row
    mov r14, rdx                ; col
    
    ; Calculate x, y
    imul r14, BUTTON_WIDTH + 5
    add r14, 5
    
    imul r13, BUTTON_HEIGHT + 5
    add r13, DISPLAY_HEIGHT + 15
    
    ; Draw button rectangle
    mov rdi, r14
    mov rsi, r13
    mov rdx, BUTTON_WIDTH
    mov rcx, BUTTON_HEIGHT
    call draw_rectangle
    
    ; Draw button label
    lea rax, [btn_labels + r12]
    mov rdi, r14
    add rdi, 20
    mov rsi, r13
    add rsi, 30
    mov rdx, rax
    mov rcx, 1
    call draw_text
    
    inc r12
    jmp .button_loop
    
.done:
    pop rbp
    ret

;========================================
; Event Loop
;========================================
event_loop:
    push rbp
    mov rbp, rsp
    
.loop:
    ; Read event
    mov rax, SYS_READ
    mov edi, [socket_fd]
    lea rsi, [event_buffer]
    mov rdx, 32
    syscall
    
    cmp rax, 0
    jle .done
    
    ; Check event type
    movzx rax, BYTE [event_buffer]
    
    cmp al, X11_EVENT_EXPOSE
    je .handle_expose
    
    cmp al, X11_EVENT_BUTTON_PRESS
    je .handle_button
    
    jmp .loop
    
.handle_expose:
    call redraw_display
    jmp .loop
    
.handle_button:
    ; Get mouse coordinates
    movzx rdi, WORD [event_buffer + 20]  ; event_x
    movzx rsi, WORD [event_buffer + 22]  ; event_y
    call handle_mouse_click
    call redraw_display
    jmp .loop
    
.done:
    pop rbp
    ret

;========================================
; Handle Mouse Click
;========================================
handle_mouse_click:
    push rbp
    mov rbp, rsp
    
    ; Check if click is in button area
    cmp rsi, DISPLAY_HEIGHT + 15
    jl .done
    
    ; Calculate button row and column
    sub rsi, DISPLAY_HEIGHT + 15
    sub rdi, 5
    
    ; row = (y - offset) / (BUTTON_HEIGHT + 5)
    mov rax, rsi
    xor rdx, rdx
    mov rcx, BUTTON_HEIGHT + 5
    div rcx
    mov r12, rax                ; row
    
    ; col = (x - offset) / (BUTTON_WIDTH + 5)
    mov rax, rdi
    xor rdx, rdx
    mov rcx, BUTTON_WIDTH + 5
    div rcx
    mov r13, rax                ; col
    
    ; Check bounds
    cmp r12, 4
    jge .done
    cmp r13, 4
    jge .done
    
    ; Calculate button index: row * 4 + col
    imul r12, 4
    add r12, r13
    
    ; Get button character
    lea rax, [btn_labels]
    add rax, r12
    movzx rdi, BYTE [rax]
    call process_button
    
.done:
    pop rbp
    ret

;========================================
; Process Button Press
;========================================
process_button:
    push rbp
    mov rbp, rsp
    
    ; Check if digit (0-9)
    cmp dil, '0'
    jl .check_operator
    cmp dil, '9'
    jg .check_operator
    
    ; It's a digit
    movzx rax, BYTE [input_len]
    cmp rax, 15
    jge .done
    
    ; Check if we need to clear first
    cmp BYTE [needs_clear], 1
    jne .append_digit
    
    mov BYTE [input_len], 0
    mov BYTE [needs_clear], 0
    
.append_digit:
    lea rsi, [input_buffer]
    add rsi, rax
    mov [rsi], dil
    inc BYTE [input_len]
    jmp .done
    
.check_operator:
    ; Check for operators
    cmp dil, '+'
    je .handle_add
    cmp dil, '-'
    je .handle_sub
    cmp dil, '*'
    je .handle_mul
    cmp dil, '/'
    je .handle_div
    cmp dil, '='
    je .handle_equals
    cmp dil, 'C'
    je .handle_clear
    jmp .done
    
.handle_add:
    mov BYTE [operator], 1
    call store_operand1
    jmp .done
    
.handle_sub:
    mov BYTE [operator], 2
    call store_operand1
    jmp .done
    
.handle_mul:
    mov BYTE [operator], 3
    call store_operand1
    jmp .done
    
.handle_div:
    mov BYTE [operator], 4
    call store_operand1
    jmp .done
    
.handle_equals:
    call calculate_result
    jmp .done
    
.handle_clear:
    mov QWORD [operand1], 0
    mov QWORD [operand2], 0
    mov QWORD [result], 0
    mov BYTE [operator], 0
    mov BYTE [input_buffer], '0'
    mov BYTE [input_len], 1
    mov BYTE [needs_clear], 0
    
.done:
    pop rbp
    ret

;========================================
; Store first operand
;========================================
store_operand1:
    push rbp
    mov rbp, rsp
    
    call parse_input
    mov [operand1], rax
    mov BYTE [needs_clear], 1
    
    pop rbp
    ret

;========================================
; Calculate Result
;========================================
calculate_result:
    push rbp
    mov rbp, rsp
    
    ; Parse current input as operand2
    call parse_input
    mov [operand2], rax
    
    ; Load operands
    mov rax, [operand1]
    mov rbx, [operand2]
    
    ; Perform operation
    movzx rcx, BYTE [operator]
    cmp rcx, 1
    je .do_add
    cmp rcx, 2
    je .do_sub
    cmp rcx, 3
    je .do_mul
    cmp rcx, 4
    je .do_div
    jmp .done
    
.do_add:
    add rax, rbx
    jmp .store_result
    
.do_sub:
    sub rax, rbx
    jmp .store_result
    
.do_mul:
    imul rax, rbx
    jmp .store_result
    
.do_div:
    cmp rbx, 0
    je .done                    ; Prevent division by zero
    xor rdx, rdx
    cqo                         ; Sign extend rax to rdx:rax
    idiv rbx
    jmp .store_result
    
.store_result:
    mov [result], rax
    
    ; Convert result to string
    mov rdi, rax
    call int_to_string
    
    mov BYTE [operator], 0
    mov BYTE [needs_clear], 1
    
.done:
    pop rbp
    ret

;========================================
; Parse input buffer to integer
;========================================
parse_input:
    push rbp
    mov rbp, rsp
    
    xor rax, rax                ; Result
    xor rcx, rcx                ; Index
    movzx rdx, BYTE [input_len]
    
.loop:
    cmp rcx, rdx
    jge .done
    
    imul rax, 10
    lea rsi, [input_buffer + rcx]
    movzx rbx, BYTE [rsi]
    sub rbx, '0'
    add rax, rbx
    
    inc rcx
    jmp .loop
    
.done:
    pop rbp
    ret

;========================================
; Convert integer to string
;========================================
int_to_string:
    push rbp
    mov rbp, rsp
    
    mov rax, rdi
    lea rsi, [num_buffer + 31]
    mov BYTE [rsi], 0
    mov rcx, 10
    
    ; Handle negative numbers
    mov r8, 0
    cmp rax, 0
    jge .convert_loop
    neg rax
    mov r8, 1
    
.convert_loop:
    xor rdx, rdx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    
    cmp rax, 0
    jne .convert_loop
    
    ; Add minus sign if negative
    cmp r8, 1
    jne .copy_to_input
    dec rsi
    mov BYTE [rsi], '-'
    
.copy_to_input:
    ; Copy to input_buffer
    lea rdi, [input_buffer]
    xor rcx, rcx
    
.copy_loop:
    mov al, [rsi]
    cmp al, 0
    je .copy_done
    mov [rdi], al
    inc rsi
    inc rdi
    inc rcx
    jmp .copy_loop
    
.copy_done:
    mov [input_len], cl
    
    pop rbp
    ret

;========================================
; Error Exit
;========================================
error_exit:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall
