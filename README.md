Build and Run Instructions

bash
# Install required packages (Ubuntu/Debian)
sudo apt-get install nasm.


# Assemble the code
nasm -f elf64 -g calculator.asm -o calculator.o

# Link the object file
ld calculator.o -o calculator

# Run the calculator (requires X11)
./calculator

Architecture and Event Handling Explanation
Architecture Overview

The calculator implements a direct X11 protocol client without using libX11, communicating through Unix domain sockets. The architecture consists of several key components:

​

X11 Connection Layer: Establishes a Unix domain socket connection to /tmp/.X11-unix/X0, performs the X11 handshake protocol, and extracts resource ID allocation parameters.

​


Resource Management: Creates X11 resources including the window, two graphics contexts (one for text, one for buttons), and a font resource. Resource IDs are generated using the id_base and id_mask values from the server handshake.

​

Calculator State Machine: Maintains state in memory with operand1 (first number), operand2 (second number), operator (operation type), and an input buffer for the current digit entry. The state machine handles transitions between entering the first operand, selecting an operator, entering the second operand, and computing results.

​
Event Handling

The event loop continuously reads 32-byte event packets from the X11 socket using the read() system call. Events are processed based on their type code in the first byte:

​

Expose Events (type 12): Triggered when the window needs repainting. The handler redraws the entire calculator interface including the display rectangle, current input text, and all 16 buttons in a 4×4 grid.

​

Button Press Events (type 4): Mouse click events contain x/y coordinates at offset 20-22 in the event structure. The handler converts screen coordinates to button indices by calculating (y - offset) / button_height for rows and (x - offset) / button_width for columns.

​
Arithmetic Implementation

All arithmetic operations are implemented using native x86-64 instructions:
​

​

    Addition: add rax, rbx - adds two 64-bit signed integers

    Subtraction: sub rax, rbx - subtracts rbx from rax

    Multiplication: imul rax, rbx - signed multiplication

​

Division: idiv rbx - signed division with dividend in rdx:rax, quotient in rax

    ​

The calculator includes division-by-zero protection by checking the divisor before executing the division instruction.

​
Memory Management

All data structures are allocated on the stack using sub rsp, N to reserve space, maintaining 16-byte alignment as required by the System V ABI. The stack stores X11 protocol packets before transmission, event buffers for incoming events, and temporary calculation buffers. Function prologues save rbp and establish stack frames, while epilogues restore the stack pointer before returning.

​

This implementation demonstrates complete X11 GUI programming in pure Assembly, handling window creation, event processing, text rendering, and arithmetic computation without any high-level language dependencies.
​

"MAKE SURE NOT TO  USE WAYLAND OR HYPRLAND"