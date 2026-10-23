"""Recognize bounded signed-relative switch tables before `br x18`.

Returns a contiguous landing-pad range. Tables remain unchanged. Every original
table destination is reconstructed and must land on aligned original text.
Unsupported patterns fail rather than treating arbitrary register jumps as a
known table. This is pattern/bytes validation, not a full control-flow proof.
"""
import struct


def register_number(name):
    if name.startswith(('x', 'w')) and name[1:].isdigit():
        return int(name[1:])
    return None


def relative_table(image, instructions, branch_index, text_end, ro_off, data_off):
    from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM, ARM64_OP_MEM
    seq = instructions
    branch = seq[branch_index]
    if branch_index < 2:
        raise ValueError('Incomplete relative jump sequence')
    load, add = seq[branch_index - 2:branch_index]
    reg = lambda op: register_number(branch.reg_name(op.reg))
    if (add.mnemonic != 'add' or len(add.operands) != 3 or
            any(o.type != ARM64_OP_REG for o in add.operands) or
            reg(add.operands[0]) != 18 or reg(add.operands[1]) != 18):
        raise ValueError('Not add x18,x18,table-base')
    base_reg = reg(add.operands[2])
    if (load.mnemonic != 'ldrsw' or len(load.operands) != 2 or
            load.operands[0].type != ARM64_OP_REG or reg(load.operands[0]) != 18 or
            load.operands[1].type != ARM64_OP_MEM):
        raise ValueError('Not a signed relative table load')
    mem = load.operands[1].mem
    if register_number(load.reg_name(mem.base)) != base_reg or mem.disp != 0:
        raise ValueError('Inconsistent table base')
    index_reg = register_number(load.reg_name(mem.index))
    if index_reg is None or load.operands[1].shift.value != 2:
        raise ValueError('Table index must have four-byte stride')

    context = seq[max(0, branch_index - 256):branch_index - 2]
    base = None
    # Symbolically follow only PC-relative construction and immediate addition.
    for ins in context:
        ops = ins.operands
        if ins.mnemonic in ('adr', 'adrp') and len(ops) == 2 and reg(ops[0]) == base_reg:
            base = ops[1].imm
        elif ins.mnemonic == 'add' and len(ops) == 3 and reg(ops[0]) == base_reg:
            base = base + ops[2].imm if reg(ops[1]) == base_reg and ops[2].type == ARM64_OP_IMM and base is not None else None
        elif ins.mnemonic not in ('cmp', 'tst') and ops and ops[0].type == ARM64_OP_REG and reg(ops[0]) == base_reg:
            # The register must not have changed after its address construction.
            base = None
    if base is None or not ro_off <= base < data_off:
        raise ValueError('No immutable table address construction')

    # Follow a direct register copy backwards to the compared source register.
    compared = index_reg
    index_mask = None
    bound = guard = None
    for n in range(len(context) - 1, -1, -1):
        ins = context[n]; ops = ins.operands
        if ins.mnemonic == 'mov' and len(ops) == 2 and all(o.type == ARM64_OP_REG for o in ops) and reg(ops[0]) == compared:
            compared = reg(ops[1]); continue
        if ins.mnemonic == 'and' and len(ops) == 3 and ops[0].type == ARM64_OP_REG and reg(ops[0]) == compared and ops[1].type == ARM64_OP_REG and ops[2].type == ARM64_OP_IMM:
            mask = ops[2].imm
            if index_mask is not None or not 0 < mask <= 65535:
                raise ValueError('Unsupported masked table index')
            compared = reg(ops[1]); index_mask = mask; continue
        guard_matches = False
        if ins.mnemonic == 'cmp' and len(ops) == 2 and ops[0].type == ARM64_OP_REG and ops[1].type == ARM64_OP_IMM:
            guard_matches = reg(ops[0]) == compared
            if not guard_matches and index_mask is not None and n > 0:
                prior = context[n - 1]; po = prior.operands
                guard_matches = (prior.mnemonic == 'and' and len(po) == 3 and
                                 po[0].type == po[1].type == ARM64_OP_REG and
                                 po[2].type == ARM64_OP_IMM and reg(po[0]) == reg(ops[0]) and
                                 reg(po[1]) == compared and po[2].imm == index_mask)
        if guard_matches:
            limit = ops[1].imm
            if n + 1 < len(context) and context[n + 1].mnemonic in ('b.hi', 'b.ls') and 0 <= limit <= 65535:
                bound = limit + 1; guard = ins.address
                break
        if ins.mnemonic not in ('cmp', 'tst') and ops and ops[0].type == ARM64_OP_REG and reg(ops[0]) == compared:
            # Unknown index reassignment cannot be justified by an older cmp.
            raise ValueError('Index changed after its range guard')
    if bound is None or base + bound * 4 > data_off:
        raise ValueError('No bounded immutable table')
    targets = [base + struct.unpack_from('<i', image, base + i * 4)[0] for i in range(bound)]
    if any(t < 0 or t >= text_end or t % 4 for t in targets):
        raise ValueError('Table destination outside aligned original text')
    first, last = min(targets), max(targets)
    count = (last - first) // 4 + 1
    if count > 65536:
        raise ValueError('Landing-pad span exceeds bounded reserve')
    return first, count, {'branch': branch.address, 'table': base,
                          'entries': bound, 'range_guard': guard,
                          'targets': targets, 'landing_first': first,
                          'landing_count': count,
                          'validation': 'relative_table_bytes_and_local_guard_pattern'}
