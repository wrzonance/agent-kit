"""Recognize only direct shell reads/help; never execute or scan embedded code."""
import json
import shlex


def direct_words(payload):
    if payload.get('name', '').rsplit('.', 1)[-1] not in {'shell', 'exec_command'}:
        return []
    try:
        args = payload.get('arguments', {})
        args = json.loads(args) if isinstance(args, str) else args
        if not isinstance(args, dict):
            return []
        command = args.get('cmd', args.get('command'))
        if isinstance(command, list):
            if not all(isinstance(word, str) for word in command):
                return []
            if len(command) == 3 and command[0] in {'bash', 'sh', 'zsh'} and command[1] in {'-c', '-lc'}:
                command = command[2]
            else:
                return command
        if not isinstance(command, str) or any(c in command for c in '\n;|&<>`$'):
            return []
        return shlex.split(command)
    except (ValueError, TypeError):
        return []


def helper(path):
    parts = path.split('/')
    return 'skills' in parts and 'scripts' in parts and path.endswith('.sh')


def read_operands(program, words):
    if '--help' in words or '--version' in words:
        return []
    if program in {'cat', 'head', 'tail'}:
        return words[1:]
    if program not in {'sed', 'rg', 'grep'}:
        return []
    # Skip known switches and the pattern/script. Decline other option grammars,
    # especially sed -i and rg --files, which do not establish source discovery.
    index = 1
    while index < len(words) and words[index] in {'-n', '-E', '-r', '-F', '-i'}:
        if program == 'sed' and words[index] == '-i':
            return []
        index += 1
    if index >= len(words) or words[index].startswith('-'):
        return []
    return words[index + 1:]


def infer_call(identity, payload):
    words = direct_words(payload)
    if not words:
        return None
    program = words[0].rsplit('/', 1)[-1]
    target = words[1] if program in {'bash', 'sh', 'zsh'} and len(words) > 1 else words[0]
    tags = []
    if helper(target) and '--help' in words[1:]:
        tags.append('help')
    paths = [w for w in read_operands(program, words) if helper(w) or
             ('skills/' in w and ('/references/' in w or '/.shared/' in w) and w.endswith('.md'))]
    read = program in {'cat', 'head', 'tail', 'sed', 'rg', 'grep'} and bool(paths)
    if read:
        if any(helper(p) for p in paths):
            tags.append('source_grep' if program in {'rg', 'grep'} else 'source_read')
        if any(p.endswith('.md') for p in paths):
            tags.append('reference_read')
    if not tags:
        return None
    annotation = {'kind': 'call', 'call_id': identity, 'tags': tags, 'evidence': f'native:{identity}'}
    if read:
        annotation['read_key'] = json.dumps(words)  # Preserve ranges and grep predicates.
    return {'payload': annotation}
