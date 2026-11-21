import ast
import io
import pathlib
import re
import tokenize

root = pathlib.Path(__file__).resolve().parent.parent
errors = []
paths = sorted([*root.joinpath('scripts').glob('*.py'), *root.joinpath('Tests').glob('*.py')])
for path in paths:
    relative = path.relative_to(root)
    if not re.fullmatch(r'(scripts|Tests)/[a-z][a-z0-9-]*\.py', str(relative)):
        errors.append(f'{relative}: Python 文件必须位于 scripts 或 Tests，并使用小写连字符命名。')
    source = path.read_text()
    tree = ast.parse(source, filename=str(relative))
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type == tokenize.COMMENT:
            errors.append(f'{relative}:{token.start[0]}: 代码文件不得包含注释。')
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and not re.fullmatch(r'[a-z_][a-z0-9_]*', node.name):
            errors.append(f'{relative}:{node.lineno}: 函数必须使用 snake_case 命名。')
        if isinstance(node, ast.ClassDef) and not re.fullmatch(r'[A-Z][A-Za-z0-9]*', node.name):
            errors.append(f'{relative}:{node.lineno}: 类必须使用 PascalCase 命名。')
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store) and not re.fullmatch(r'[a-z_][a-z0-9_]*|[A-Z][A-Z0-9_]*', node.id):
            errors.append(f'{relative}:{node.lineno}: 变量必须使用 snake_case，常量必须使用 UPPER_SNAKE_CASE。')
        if isinstance(node, ast.ExceptHandler) and node.type is None:
            errors.append(f'{relative}:{node.lineno}: 不得使用裸 except。')
        if isinstance(node, ast.ImportFrom) and any(item.name == '*' for item in node.names):
            errors.append(f'{relative}:{node.lineno}: 不得使用通配符导入。')
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in {'eval', 'exec'}:
            errors.append(f'{relative}:{node.lineno}: 不得动态执行代码字符串。')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Python lint: {len(paths)} files, 0 violations')
