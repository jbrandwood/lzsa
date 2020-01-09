; ***************************************************************************
; ***************************************************************************
;
; lzsa2_6502.s
;
; NMOS 6502 decompressor for data stored in Emmanuel Marty's LZSA2 format.
;
; Optional code is presented for two minor 6502 optimizations that break
; compatibility with the current LZSA2 format standard.
;
; This code is written for the PCEAS/NECASM assembler in HuC & MagicKit.
;
; Copyright John Brandwood 2019.
;
; Distributed under the Boost Software License, Version 1.0.
; (See accompanying file LICENSE_1_0.txt or copy at
;  http://www.boost.org/LICENSE_1_0.txt)
;
; ***************************************************************************
; ***************************************************************************



; ***************************************************************************
; ***************************************************************************
;
; Decompression Options & Macros
;

                ;
                ; Save 7 bytes of code, and 21 cycles every time that a 
                ; 16-bit length is decoded?
                ;
                ; N.B. Setting this breaks compatibility with LZSA v1.2
                ;

LZSA_SWAP_LEN16 =       0

                ;
                ; Save 3 bytes of code, and 4 or 8 cycles when decoding
                ; an offset?
                ;
                ; N.B. Setting this breaks compatibility with LZSA v1.2
                ;

LZSA_SWAP_XZY   =       0

                ;
                ; Remove code inlining to save space?
                ;
                ; This saves 15 bytes of code, but decompression is 7% slower.
                ;

LZSA_BEST_SIZE  =       0

                ;
                ; Assume that we're decompessing from a large multi-bank
                ; compressed data file, and that the next bank may need to
                ; paged in when a page-boundary is crossed.
                ;

LZSA_FROM_BANK  =       0

                ;
                ; Macro to increment the source pointer to the next page.
                ;

                if      LZSA_FROM_BANK
LZSA_INC_PAGE   macro
                jsr     .next_page
                endm
                else
LZSA_INC_PAGE   macro
                inc     <lzsa_srcptr + 1
                endm
                endif

                ;
                ; Macro to read a byte from the compressed source data.
                ;

                if      LZSA_BEST_SIZE

LZSA_GET_SRC    macro
                jsr     .get_byte
                endm

                else

LZSA_GET_SRC    macro
                lda     [lzsa_srcptr],y
                inc     <lzsa_srcptr + 0
                bne     .skip\@
                LZSA_INC_PAGE
.skip\@:
                endm

                endif

                ;
                ; Macro to speed up reading 50% of nibbles.
                ;

LZSA_SLOW_NIBL  =       1

                if      (LZSA_SLOW_NIBL + LZSA_BEST_SIZE)

LZSA_GET_NIBL   macro
                jsr     .get_nibble             ; Always call a function.
                endm

                else

LZSA_GET_NIBL   macro
                lsr     <lzsa_nibflg            ; Is there a nibble waiting?
                lda     <lzsa_nibble            ; Extract the lo-nibble.
                bcs     .skip\@
                jsr     .new_nibble             ; Extract the hi-nibble.
.skip\@:        ora     #$F0
                endm

                endif



; ***************************************************************************
; ***************************************************************************
;
; Data usage is last 11 bytes of zero-page.
;

lzsa_cmdbuf     =       $00F5                   ; 1 byte.
lzsa_nibflg     =       $00F6                   ; 1 byte.
lzsa_nibble     =       $00F7                   ; 1 byte.
lzsa_offset     =       $00F8                   ; 1 word.
lzsa_winptr     =       $00FA                   ; 1 word.
lzsa_srcptr     =       $00FC                   ; 1 word.
lzsa_dstptr     =       $00FE                   ; 1 word.



; ***************************************************************************
; ***************************************************************************
;
; lzsa2_unpack - Decompress data stored in Emmanuel Marty's LZSA2b format.
;
; Args: lzsa_srcptr = ptr to compessed data
; Args: lzsa_dstptr = ptr to output buffer
; Uses: lots!
;
; If compiled with LZSA_FROM_BANK, then lzsa_srcptr should be within the bank
; window range.
;

lzsa2_unpack:   ldy     #0                      ; Initialize source index.
                sty     <lzsa_nibflg            ; Initialize nibble buffer.

                ;
                ; Copy bytes from compressed source data.
                ;

.cp_length:     ldx     #$00                    ; Hi-byte of length or offset.

                LZSA_GET_SRC
                sta     <lzsa_cmdbuf            ; Preserve this for later.
                and     #$18                    ; Extract literal length.
                beq     .lz_offset              ; Skip directly to match?

                lsr     a                       ; Get 2-bit literal length.
                lsr     a
                lsr     a
                cmp     #$03                    ; Extended length?
                bne     .got_cp_len

                jsr     .get_length             ; X=0 table index for literals.

.got_cp_len:    tay                             ; Check the lo-byte of length.
                beq     .cp_page

                inx                             ; Increment # of pages to copy.

.get_cp_src:    clc                             ; Calc source for partial
                adc     <lzsa_srcptr + 0        ; page.
                sta     <lzsa_srcptr + 0
                bcs     .get_cp_dst
                dec     <lzsa_srcptr + 1

.get_cp_dst:    tya
                clc                             ; Calc destination for partial
                adc     <lzsa_dstptr + 0        ; page.
                sta     <lzsa_dstptr + 0
                bcs     .get_cp_idx
                dec     <lzsa_dstptr + 1

.get_cp_idx:    tya                             ; Negate the lo-byte of length.
                eor     #$FF
                tay
                iny

.cp_page:       lda     [lzsa_srcptr],y
                sta     [lzsa_dstptr],y
                iny
                bne     .cp_page
                inc     <lzsa_srcptr + 1
                inc     <lzsa_dstptr + 1
                dex                             ; Any full pages left to copy?
                bne     .cp_page

                if      LZSA_SWAP_XZY

                ;
                ; Shorter and faster path with NEW order of bits.
                ;
                ; STD  NEW
                ; ================================ 
                ; xyz  xzy
                ; 00z  0z0  5-bit offset
                ; 01z  0z1  9-bit offset
                ; 10z  1z0  13-bit offset
                ; 110  101  16-bit offset
                ; 111  111  repeat offset
                ;      NVZ  for a BIT instruction
                ;
                ; N.B. Saves 3 bytes in code length.
                ;      get5 and get13 are 8 cycles faster.
                ;      get9, get16, and rep are 4 cycles faster.
                ;

.lz_offset:     lda     #$20                    ; Y bit in lzsa_cmdbuf.
                bit     <lzsa_cmdbuf
                bmi     .get_13_16_rep
                bne     .get_9_bits

.get_5_bits:    dex                             ; X=$FF
.get_13_bits:   LZSA_GET_NIBL                   ; Always returns with CS.
                bvc     .get_5_skip
                clc
.get_5_skip:    rol     a                       ; Shift into position, set C.
                cpx     #$00                    ; X=$FF for a 5-bit offset.
                bne     .set_offset
                sbc     #2                      ; Subtract 512 because 13-bit
                tax                             ; offset starts at $FE00.
                bne     .get_low8               ; Always NZ from previous TAX.

.get_9_bits:    dex                             ; X=$FF if VC, X=$FE if VS.
                bvc     .get_low8
                dex
                bvs     .get_low8               ; Always VS from previous BIT.

.get_13_16_rep: beq     .get_13_bits            ; Shares code with 5-bit path.

.get_16_rep:    bvs     .lz_length              ; Repeat previous offset.

                else

                ;
                ; Slower and longer path with STD order of bits.
                ;
                ; Z80  NES
                ; ================================ 
                ; xyz  xzy
                ; 00z  0z0  5-bit offset
                ; 01z  0z1  9-bit offset
                ; 10z  1z0  13-bit offset
                ; 110  101  16-bit offset
                ; 111  111  repeat offset
                ;      NVZ  for a BIT instruction
                ;

.lz_offset:     lda     <lzsa_cmdbuf
                asl     a
                bcs     .get_13_16_rep
                asl     a
                bcs     .get_9_bits

.get_5_bits:    dex                             ; X=$FF
.get_13_bits:   asl     a
                php
                LZSA_GET_NIBL                   ; Always returns with CS.
                plp
                rol     a                       ; Shift into position, set C.
                eor     #$01
                cpx     #$00                    ; X=$FF for a 5-bit offset.
                bne     .set_offset
                sbc     #2                      ; Subtract 512 because 13-bit
                tax                             ; offset starts at $FE00.
                bne     .get_low8               ; Always NZ from previous TAX.

.get_9_bits:    dex                             ; X=$FF if CS, X=$FE if CC.
                asl     a
                bcc     .get_low8
                dex
                bcs     .get_low8               ; Always VS from previous BIT.

.get_13_16_rep: asl     a
                bcc     .get_13_bits            ; Shares code with 5-bit path.

.get_16_rep:    bmi     .lz_length              ; Repeat previous offset.

                endif

                ;
                ; Copy bytes from decompressed window.
                ;
                ; N.B. X=0 is expected and guaranteed when we get here.
                ;

.get_16_bits:   jsr     .get_byte               ; Get hi-byte of offset.
                tax

.get_low8:      LZSA_GET_SRC                    ; Get lo-byte of offset.

.set_offset:    stx     <lzsa_offset + 1        ; Save new offset.
                sta     <lzsa_offset + 0

.lz_length:     ldx     #$00                    ; Hi-byte of length.

                lda     <lzsa_cmdbuf
                and     #$07
                clc
                adc     #$02
                cmp     #$09                    ; Extended length?
                bne     .got_lz_len

                inx
                jsr     .get_length             ; X=1 table index for match.

.got_lz_len:    eor     #$FF                    ; Negate the lo-byte of length
                tay                             ; and check for zero.
                iny
                beq     .calc_lz_addr
                eor     #$FF

                inx                             ; Increment # of pages to copy.

                clc                             ; Calc destination for partial
                adc     <lzsa_dstptr + 0        ; page.
                sta     <lzsa_dstptr + 0
                bcs     .calc_lz_addr
                dec     <lzsa_dstptr + 1

.calc_lz_addr:  clc                             ; Calc address of match.
                lda     <lzsa_dstptr + 0        ; N.B. Offset is negative!
                adc     <lzsa_offset + 0
                sta     <lzsa_winptr + 0
                lda     <lzsa_dstptr + 1
                adc     <lzsa_offset + 1
                sta     <lzsa_winptr + 1

.lz_page:       lda     [lzsa_winptr],y
                sta     [lzsa_dstptr],y
                iny
                bne     .lz_page
                inc     <lzsa_winptr + 1
                inc     <lzsa_dstptr + 1
                dex                             ; Any full pages left to copy?
                bne     .lz_page

                jmp     .cp_length              ; Loop around to the beginning.

                ;
                ; Lookup tables to differentiate literal and match lengths.
                ;

.nibl_len_tbl:  db      3 + $10                 ; 0+3 (for literal).
                db      9 + $10                 ; 2+7 (for match).

.byte_len_tbl:  db      18 - 1                  ; 0+3+15 - CS (for literal).
                db      24 - 1                  ; 2+7+15 - CS (for match).

                ;
                ; Get 16-bit length in X:A register pair.
                ;
                ; N.B. Requires reversal of bytes in 16-bit length.
                ;

.get_length:    LZSA_GET_NIBL
                cmp     #$FF                    ; Extended length?
                bcs     .byte_length
                adc     .nibl_len_tbl,x         ; Always CC from previous CMP.

.got_length:    ldx     #$00                    ; Set hi-byte of 4 & 8 bit
                rts                             ; lengths.

.byte_length:   jsr     .get_byte               ; So rare, this can be slow!
                adc     .byte_len_tbl,x         ; Always CS from previous CMP.
                bcc     .got_length
                beq     .finished

                if      LZSA_SWAP_LEN16

.word_length:   jsr     .get_byte               ; So rare, this can be slow!
                tax

                else

.word_length:   jsr     .get_byte               ; So rare, this can be slow!
                pha
                jsr     .get_byte               ; So rare, this can be slow!
                tax
                pla
                rts

                endif

.get_byte:      lda     [lzsa_srcptr],y         ; Subroutine version for when
                inc     <lzsa_srcptr + 0        ; inlining isn't advantageous.
                beq     .next_page
                rts

.next_page:     inc     <lzsa_srcptr + 1        ; Inc & test for bank overflow.
                if      LZSA_FROM_BANK
                bmi     .next_bank              ; Change for target hardware!
                endif
                rts

.finished:      pla                             ; Decompression completed, pop
                pla                             ; return address.
                rts

                ;
                ; Get a nibble value from compressed data in A.
                ;

                if      (LZSA_SLOW_NIBL + LZSA_BEST_SIZE)

.get_nibble:    lsr     <lzsa_nibflg            ; Is there a nibble waiting?
                lda     <lzsa_nibble            ; Extract the lo-nibble.
                bcs     .got_nibble

                inc     <lzsa_nibflg            ; Reset the flag.
                LZSA_GET_SRC
                sta     <lzsa_nibble            ; Preserve for next time.
                lsr     a                       ; Extract the hi-nibble.
                lsr     a
                lsr     a
                lsr     a

                if      LZSA_SWAP_XZY
                sec                             ; Offset code relies on CS.
                endif

.got_nibble:    ora     #$F0
                rts

                else

.new_nibble:    inc     <lzsa_nibflg            ; Reset the flag.
                LZSA_GET_SRC
                sta     <lzsa_nibble            ; Preserve for next time.
                lsr     a                       ; Extract the hi-nibble.
                lsr     a
                lsr     a
                lsr     a

                if      LZSA_SWAP_XZY
                sec                             ; Offset code relies on CS.
                endif

                rts

                endif
