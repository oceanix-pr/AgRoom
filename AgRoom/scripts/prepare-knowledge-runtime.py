#!/usr/bin/env python3
"""Rebuild the pinned, MIT-licensed llama.cpp embedding/intent helpers for both Mac architectures.

Developer-only preparation; no model weights are downloaded or packaged here.
Use --cache-dir to reuse previously verified official archives.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

TAG = 'b11580'
ARCHIVES = {
    'arm64': ('llama-b11580-bin-macos-arm64.tar.gz', 'ca2ba63aa7c18e06b0dcd339273c605cba8fdc1b607521e6ea598841ec5462c5'),
    'x86_64': ('llama-b11580-bin-macos-x64.tar.gz', '882c2620879d8b2c79fad1db63160bc8a556be0a7fb135a09e8cd12bafa636b8'),
}
SOURCE_HASH = 'd1767899cde5a6f697c4d68e6cc9938176c620c4b4485d5e9d2053d75f72d5a2'
ENTRY_SOURCES = {'llama-embedding': 'scripts/knowledge-embedding-main.cpp',
                 'llama-intent': 'scripts/intent-routing-main.cpp'}
PROJECT = Path(__file__).resolve().parent.parent


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for data in iter(lambda: source.read(1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def fetch(url, destination, expected):
    if not destination.exists() or sha256(destination) != expected:
        staging = destination.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--max-time', '600', url, '-o', str(staging)], check=True)
        if sha256(staging) != expected:
            raise RuntimeError('Official archive checksum mismatch: ' + destination.name)
        staging.replace(destination)
    if sha256(destination) != expected:
        raise RuntimeError('Archive checksum mismatch')


def extract(archive, directory):
    directory.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            target = (directory / member.name).resolve()
            if not target.is_relative_to(directory.resolve()):
                raise RuntimeError('Unsafe archive path')
            if member.issym() and not (target.parent / member.linkname).resolve().is_relative_to(directory.resolve()):
                raise RuntimeError('Unsafe archive symlink')
        package.extractall(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-dir', type=Path, default=Path(tempfile.gettempdir()) / 'agroom-runtime-archives')
    args = parser.parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    source_archive = args.cache_dir / ('llama-' + TAG + '-source.tar.gz')
    fetch('https://codeload.github.com/ggml-org/llama.cpp/tar.gz/refs/tags/' + TAG, source_archive, SOURCE_HASH)
    environment = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=environment, text=True).strip()
    target = PROJECT / 'Sources/AgRoom/EmbeddingRuntime'
    with tempfile.TemporaryDirectory(prefix='agroom-runtime-build-') as temporary:
        work = Path(temporary)
        extract(source_archive, work / 'source')
        source = next((work / 'source').iterdir())
        staging = work / 'EmbeddingRuntime'
        staging.mkdir()
        for arch, (filename, checksum) in ARCHIVES.items():
            archive = args.cache_dir / filename
            fetch('https://github.com/ggml-org/llama.cpp/releases/download/' + TAG + '/' + filename, archive, checksum)
            extract(archive, work / arch)
            libraries = work / arch / ('llama-' + TAG)
            destination = staging / arch
            destination.mkdir()
            for entry, entry_source in ENTRY_SOURCES.items():
                args_compile = ['xcrun', 'clang++', '-arch', arch, '-std=c++17', '-O2', '-mmacosx-version-min=15.0', '-isysroot', sdk,
                                '-ffile-prefix-map=' + str(source) + '=llama.cpp']
                for folder in ['common', 'include', 'ggml/include']:
                    args_compile += ['-I', str(source / folder)]
                # __FILE__ appears in GGML_ASSERT diagnostics shipped in the binaries.
                args_compile += [entry_source, '-L', str(libraries),
                                 '-lllama-common', '-lllama', '-lggml', '-lggml-base', '-Wl,-rpath,@executable_path',
                                 '-o', str(libraries / entry)]
                subprocess.run(args_compile, check=True, env=environment, cwd=PROJECT)
            pending, copied = list(ENTRY_SOURCES), set()
            while pending:
                name = pending.pop()
                if name in copied:
                    continue
                copied.add(name)
                shutil.copy2(libraries / name, destination / name)
                dependencies = subprocess.check_output(['otool', '-L', str(libraries / name)], text=True)
                for line in dependencies.splitlines()[1:]:
                    dependency = line.strip().split(' (')[0]
                    if dependency.startswith('@rpath/'):
                        pending.append(Path(dependency).name)
            shutil.copy2(libraries / 'LICENSE', destination / 'LICENSE')
        shutil.copytree(source / 'licenses', staging / 'licenses')
        for vendor, name in [('cpp-httplib/LICENSE', 'LICENSE-cpp-httplib'),
                             ('hash/xxhash/LICENSE', 'LICENSE-xxhash'),
                             ('hash/rotate-bits/LICENSE.md', 'LICENSE-rotate-bits'),
                             ('hash/sha256/LICENSE', 'LICENSE-sha256')]:
            shutil.copy2(source / 'vendor' / vendor, staging / 'licenses' / name)
        subprocess_notice = (source / 'vendor/sheredom/subprocess.h').read_text().split('#ifndef', 1)[0]
        (staging / 'licenses/LICENSE-subprocess').write_text(subprocess_notice)
        manifest = {'upstream': 'https://github.com/ggml-org/llama.cpp', 'tag': TAG, 'license': 'MIT',
                    'sourceSHA256': SOURCE_HASH, 'archives': ARCHIVES,
                    'entrySource': 'scripts/knowledge-embedding-main.cpp',
                    'entrySources': ENTRY_SOURCES,
                    'patch': 'Embedding null-context guard; bounded stateless intent generation; both helpers stop when the parent exits.'}
        (staging / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Prepare in the same filesystem, then switch. Existing runtime is retained on activation failure.
        sibling = target.with_name('EmbeddingRuntime-prepared')
        if sibling.exists():
            raise RuntimeError('Existing prepared runtime directory; inspect it before retrying')
        shutil.copytree(staging, sibling)
        backup = target.with_name('EmbeddingRuntime-previous')
        if backup.exists():
            raise RuntimeError('Existing previous runtime directory; inspect it before retrying')
        if target.exists():
            target.rename(backup)
        try:
            sibling.rename(target)
        except Exception:
            if backup.exists():
                backup.rename(target)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    print('Prepared bundled embedding runtime:', target)


if __name__ == '__main__':
    main()
