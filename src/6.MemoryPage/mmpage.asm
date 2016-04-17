; ==========================================
; pm.asm
; 编译方法：nasm pm.asm -o pm.bin
; ==========================================

%include	"pm.inc"	; 常量, 宏, 以及一些说明

PageDirBase		equ	200000h	; 页目录开始地址: 2M
PageTblBase		equ	201000h	; 页表开始地址: 2M+4K

org	0100h
	jmp	LABEL_BEGIN

[SECTION .gdt]
; GDT
;                                                                         段基址,        段界限     ,                              属性
LABEL_GDT:	                      Descriptor          0,                0,                                         0                  ; 空描述符
LABEL_DESC_PAGE_DIR: Descriptor PageDirBase, 4095, DA_DRW;Page Directory
LABEL_DESC_PAGE_TBL: Descriptor PageTblBase, 1023, DA_DRW|DA_LIMIT_4K;Page Tables
LABEL_DESC_CODE32: Descriptor           0,             SegCode32Len - 1,    DA_C + DA_32   ; 非一致代码段
LABEL_DESC_VIDEO:    Descriptor    0B8000h,     0ffffh,                              DA_DRW	       ; 显存首地址
LABEL_DESC_DATA:   Descriptor    0,      DataLen-1, DA_DRW    ; Data
LABEL_DESC_STACK:  Descriptor    0,     TopOfStack, DA_DRWA+DA_32; Stack, 32 位

; GDT 结束

GdtLen		equ	$ - LABEL_GDT	; GDT长度
GdtPtr		dw	GdtLen - 1	; GDT界限
					dd	0		; GDT基地址

; GDT 选择子
SelectorPageDir		equ	LABEL_DESC_PAGE_DIR	- LABEL_GDT
SelectorPageTbl		equ	LABEL_DESC_PAGE_TBL	- LABEL_GDT
SelectorCode32		equ	LABEL_DESC_CODE32	- LABEL_GDT
SelectorVideo		equ	LABEL_DESC_VIDEO	- LABEL_GDT
SelectorData		equ	LABEL_DESC_DATA		- LABEL_GDT
SelectorStack		equ	LABEL_DESC_STACK	- LABEL_GDT
; END of [SECTION .gdt]

[SECTION .data1]	 ; 数据段
ALIGN	32
[BITS	32]
LABEL_DATA:
BootMessage:		db	"Joey, I'm in protected mode!"
OffsetPMMessage		equ	BootMessage - $$		;表示字符串BootMessage相对于本节的开始处（LABEL_DATA）的偏移
StrTest:		db	"ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0
OffsetStrTest		equ	StrTest - $$
DataLen			equ	$ - LABEL_DATA
; END of [SECTION .data1]

; 全局堆栈段
[SECTION .gs]
ALIGN	32
[BITS	32]
LABEL_STACK:
	times 25 db 0

TopOfStack	equ	$ - LABEL_STACK - 1

; END of [SECTION .gs]

[SECTION .s16]
[BITS	16]
LABEL_BEGIN:
	mov	ax, cs
	mov	ds, ax
	mov	es, ax
	mov	ss, ax
	mov	sp, 0100h

	; 初始化 32 位代码段描述符
	xor	eax, eax
	mov	ax, cs
	shl	eax, 4
	add	eax, LABEL_SEG_CODE32
	mov	word [LABEL_DESC_CODE32 + 2], ax
	shr	eax, 16
	mov	byte [LABEL_DESC_CODE32 + 4], al
	mov	byte [LABEL_DESC_CODE32 + 7], ah

	; 初始化数据段描述符
	xor	eax, eax
	mov	ax, ds
	shl	eax, 4
	add	eax, LABEL_DATA
	mov	word [LABEL_DESC_DATA + 2], ax
	shr	eax, 16
	mov	byte [LABEL_DESC_DATA + 4], al
	mov	byte [LABEL_DESC_DATA + 7], ah

	; 初始化堆栈段描述符
	xor	eax, eax
	mov	ax, ds
	shl	eax, 4
	add	eax, LABEL_STACK
	mov	word [LABEL_DESC_STACK + 2], ax
	shr	eax, 16
	mov	byte [LABEL_DESC_STACK + 4], al
	mov	byte [LABEL_DESC_STACK + 7], ah

	; 为加载 GDTR 作准备
	xor	eax, eax
	mov	ax, ds
	shl	eax, 4
	add	eax, LABEL_GDT		; eax <- gdt 基地址
	mov	dword [GdtPtr + 2], eax	; [GdtPtr + 2] <- gdt 基地址

	; 加载 GDTR
	lgdt	[GdtPtr]

	; 关中断
	cli

	; 打开地址线A20
	in	al, 92h
	or	al, 00000010b
	out	92h, al

	; 准备切换到保护模式
	mov	eax, cr0
	or	eax, 1
	mov	cr0, eax

	; 真正进入保护模式
	jmp	dword SelectorCode32:0	; 执行这一句会把 SelectorCode32 装入 cs,
					; 并跳转到 SelectorCode32:0  处
; END of [SECTION .s16]


[SECTION .s32]; 32 位代码段. 由实模式跳入.
[BITS	32]

LABEL_SEG_CODE32:
	call	SetupPaging

	mov	ax, SelectorData
	mov	ds, ax			; 数据段选择子
	mov	ax, SelectorVideo
	mov	gs, ax			; 视频段选择子(目的)

	mov	ax, SelectorStack
	mov	ss, ax			; 堆栈段选择子

	mov	esp, TopOfStack

; 下面显示一个字符串
	mov ecx, 28
	xor	esi, esi
	xor	edi, edi
	mov	edi, 0
	mov	esi, OffsetPMMessage	; 源数据偏移
.show:
	mov	ah, 0Ch			; 0000: 黑底    1100: 红字
	mov	al, [ds:esi]
	mov	[gs:edi], ax
	inc edi
	inc edi
	inc esi
	loop .show
; 显示完毕

	; 到此停止
	jmp	$

; 启动分页机制 --------------------------------------------------------------
SetupPaging:
	; 为简化处理, 所有线性地址对应相等的物理地址.

	; 首先初始化页目录
	mov	ax, SelectorPageDir	; 此段首地址为 PageDirBase
	mov	es, ax
	mov	ecx, 1024		; 共 1K 个表项
	xor	edi, edi	;此时es:edi就指向了页目录表的开始
	xor	eax, eax
	mov	eax, PageTblBase | PG_P  | PG_USU | PG_RWW;让当前(第一个)PDE对应的页表首地址变成PageTblBase，属性是存在的可读写的用户级别页表
.1:
	stosd	;第一次执行时就把eax中的PageTblBase | PG_P  | PG_USU | PG_RWW存入了页目录表的第一个PDE
	add	eax, 4096		; 为了简化, 所有页表在内存中是连续的.将下一个页表的首地址增加4096字节
	loop	.1

	; 再初始化所有页表 (1K 个, 4M 内存空间)
	mov	ax, SelectorPageTbl	; 此段首地址为 PageTblBase
	mov	es, ax
	mov	ecx, 1024 * 1024	; 共 1M 个页表项, 也即有 1M 个页
	xor	edi, edi
	xor	eax, eax
	mov	eax, PG_P  | PG_USU | PG_RWW	;表示此PTE指示的页首地址为0
.2:
	stosd
	add	eax, 4096		; 每一页指向 4K 的空间
	loop	.2

	mov	eax, PageDirBase
	mov	cr3, eax		;首先让cr3指向页目录表
	mov	eax, cr0
	or	eax, 80000000h
	mov	cr0, eax		;设置cr0的PG位
	jmp	short .3
.3:
	nop

	ret
; 分页机制启动完毕 ----------------------------------------------------------

SegCode32Len	equ	$ - LABEL_SEG_CODE32
; END of [SECTION .s32]

