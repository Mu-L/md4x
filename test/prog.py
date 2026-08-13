#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from subprocess import *
import platform
import os

def pipe_through_prog(argv, text, timeout=None):
    p1 = Popen(argv, stdout=PIPE, stdin=PIPE, stderr=PIPE)
    try:
        [result, err] = p1.communicate(input=text.encode('utf-8'), timeout=timeout)
    except TimeoutExpired:
        # Timed cases need a hard cap: a reintroduced quadratic path does not
        # merely run slow, it can run for minutes. Kill the child so the
        # caller's `except TimeoutExpired` does not leave it behind.
        p1.kill()
        p1.communicate()
        raise
    return [p1.returncode, result.decode('utf-8'), err]

class Prog:
    def __init__(self, cmdline="md4x", default_options=[]):
        self.cmdline = cmdline.split()
        if len(self.cmdline) <= 1:
            # cmdline provided no command line options. Use default ones.
            if isinstance(default_options, str):
                self.cmdline += default_options.split()
            else:
                self.cmdline += default_options
        self.to_html = lambda x, timeout=None: pipe_through_prog(self.cmdline, x, timeout)
