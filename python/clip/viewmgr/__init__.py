#!/usr/bin/env python
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2011-2018 ANSSI. All Rights Reserved.
#
# Python module to identify and manage viewers.
# Copyright 2011 ANSSI
# Author: Mickaël Salaün <clipos@ssi.gouv.fr>

from Xlib import display, X, Xatom, error
import re
from subprocess import Popen
import time
from threading import Thread, Lock
import wnck
import gtk

LEVEL_NAME = {
    0: 'core',
    1: 'unknown',
    2: 'rm_h', 
    3: 'rm_b'
}
LEVEL_NB = dict((v,k) for k,v in LEVEL_NAME.iteritems())

LEVEL_FOCUS_FILE = '/usr/local/var/xdom_focus'
LEVEL_RM_FILE = '/usr/local/var/xdom_rm'

class WatchThread(Thread):
    def __init__(self, launcher, *args):
        super(self.__class__, self).__init__()
        self.launcher = launcher
        self.args = args
        self._go = True
        self._son = None

    def is_running(self):
        return self._son != None and self._son.is_alive()

    def run(self):
        while self._go:
            self._son = self.launcher(*self.args)
            self._son.start()
            self._son.join()

    def stop(self):
        self._go = False
        self._son.stop()

    def __del__(self):
        self.stop()

class LaunchCmd(Thread):
    def __init__(self, cmd):
        super(self.__class__, self).__init__()
        if isinstance(cmd, str):
            cmd = [cmd]
        self.cmd = cmd
        self.proc = None
        self.ret = None

    def run(self):
        self.proc = Popen(self.cmd, shell=False)
        self.ret = self.proc.wait()

    def stop(self):
        if self.proc:
            try:
                # TODO: childs deserved to die too !
                self.proc.kill()
            except OSError:
                pass

    def __del__(self):
        self.stop()

class Viewer(object):
    '''Level viewer'''

    def __init__(self, dpy, props):
        self.dpy = dpy
        assert isinstance(props, ViewStruct)
        self.props = props
        self.exe = None
        self._window = None
        self.lock_launch = Lock()
        self.lock_focus = Lock()
        #self.update()
        if self.props.start:
            self.launch()

    def win_alive(self):
        wok = False
        try:
            if self._window == None:
                wok = self._find_window()
            else:
                wok = self._match_window(self._window)
        except RuntimeError:
            pass
        return wok

    def _get_win_atom(self, win, atom_name):
        atom_id = self.dpy.get_atom(atom_name)
        try:
            return win.get_full_property(property=atom_id, type=0).value
        except AttributeError:
            return None

    def match_level(self, win_or_level):
        try:
            if isinstance(win_or_level, str):
                level = LEVEL_NB[win_or_level]
            else:
                level = win_or_level.security_query_trust_level().trust_level
            return self.props.level == level
        except error.BadWindow:
            pass
        except AttributeError:
            pass
        return False

    def _match_window(self, win):
        try:
            wm_class = win.get_wm_class()
            title = self._get_win_atom(win, '_NET_WM_VISIBLE_NAME')
            if self.match_level(win) and win.get_attributes().map_state == X.IsViewable and wm_class and self.props.class_re.match(wm_class[1]) and title and self.props.title_re.match(title):
                self._window = win
                return True
        except error.BadWindow:
            pass
        except AttributeError:
            pass
        return False

    def _find_window(self):
        try:
            for win1 in self.dpy.screen().root.query_tree().children:
                if self._match_window(win1):
                    return True
                for win2 in win1.query_tree().children:
                    if self._match_window(win2):
                        return True
        except (error.BadWindow, RuntimeError):
            pass
        return False

    def _notify(self, msg):
        print('notify_viewer: {0}'.format(msg))

    @property
    def window(self):
        self.launch()
        return self._window

    def stop(self):
        self.exe.stop()
        try:
            self._window.destroy()
        except:
            pass

    def launch(self, check=True):
        if not self.lock_launch.acquire(False):
            return
        try:
            if check and self.exe and self.exe.is_running():
                if self._wait_win():
                    return
                self.exe.stop()
            self._notify('Ouverture du bureau')
            self.exe = WatchThread(LaunchCmd, self.props.cmd)
            self.exe.start()
            self.focus()
            #Thread(target=self.focus).start()
        finally:
            self.lock_launch.release()
        ## TODO: check return value and warn user if something wrong
        ##raise ViewerError('Error on launching')

    def _wait_win(self):
        # Search 10 sec...
        for i in xrange(50):
            if self._find_window():
                return True
            if not self.exe.is_running():
                break
            time.sleep(.2)
        return False

    def focus(self):
        # TODO: force and verify the focus
        if self._wait_win():
            if self.window != None:
                self.window.set_input_focus(X.RevertToParent, X.CurrentTime)
                return True
        return False

class ViewerError(Exception):
    pass

class ViewStruct(object):
    def __init__(self, cmd, level, wm_class, title, start=False):
        self.cmd = cmd.split()
        self.level = LEVEL_NB[level]
        self.class_re = re.compile(wm_class)
        self.title_re = re.compile(title)
        self.name = level
        self.start = start

class SwitchView(object):
    '''Switch from a trusted level viewer to the next one'''

    def __init__(self, handler_focus, handler_rm, display_name=None, viewer1=None, viewer2=None):
        '''handler_*(self, level): called for each stack window changes'''
        self.lock_handler = Lock()
        self.lock_switch = Lock()
        self.handler_client_focus = handler_focus
        self.handler_client_rm = handler_rm
        self.level_focus = LEVEL_NAME[1]
        self.level_rm = self.level_focus
        for fname in [LEVEL_FOCUS_FILE, LEVEL_RM_FILE]:
            with open(fname, 'w') as fd:
                fd.write(self.level_focus)
        while gtk.events_pending():
            gtk.main_iteration()
        self.dpy = display.Display(display_name)
        # TODO: use display_name for wnck too
        self.scr = wnck.screen_get_default()
        self.view_current = Viewer(self.dpy, viewer1)
        if viewer2:
            self.view_previous = Viewer(self.dpy, viewer2)
        else:
            self.view_previous = None
        self.scr.connect("active-window-changed", self.handler_switch)
        self.scr.connect("window-stacking-changed", self.handler_order)


    def _get_trust_level(self, win=None):
        if win != None:
            trust_level = win.security_query_trust_level().trust_level
            try:
                return LEVEL_NAME[trust_level]
            except KeyError:
                pass
        return LEVEL_NAME[1]

    def get_level(self, dpy, xid):
        try:
            for win1 in dpy.screen().root.query_tree().children:
                if win1.id == xid:
                    return self._get_trust_level(win1)
                for win2 in win1.query_tree().children:
                    if win2.id == xid:
                        return self._get_trust_level(win2)
        except:
            pass
        return self._get_trust_level()

    def handler_window(self, level=None):
        '''Keep up to date the stack view order'''
        if level != self.level_focus:
            self._handler_window_force(level)

    def _handler_window_force(self, level=None):
        with self.lock_handler:
            # XXX
            if level == None:
                try:
                    level = LEVEL_NAME[self.view_current.props.level]
                except AttributeError:
                    return
            if level != None:
                self.level_focus = level
                if level != self.level_rm and level in [LEVEL_NAME[2], LEVEL_NAME[3]]:
                    self.level_rm = level
                    if self.view_previous and self.view_previous.match_level(level):
                        self.view_current, self.view_previous = \
                            self.view_previous, self.view_current
                        
                    with open(LEVEL_RM_FILE, 'w') as f:
                        f.write(self.level_rm)
                    self.handler_client_rm(level)
                with open(LEVEL_FOCUS_FILE, 'w') as f:
                    f.write(self.level_focus)
                self.handler_client_focus(level)
                #if not self.view_previous.match_level(level):
                #    self._switch_nocheck()
                #self._switch_nocheck()

    def handler_switch(self, screen, window=None):
        self.handler_order(screen)

    def handler_order(self, screen):
        win = screen.get_active_window()
        try:
            win_xid = win.get_xid()
        except AttributeError:
            win_xid = None
        level = self.get_level(self.dpy, win_xid)
        self.handler_window(level)

    def _fake_event(self):
        # TODO: multi screen
        self.handler_order(self.scr)

    def stop(self):
        for view in [self.view_current, self.view_previous]:
          if view:
            try:
                view.stop()
            except AttributeError:
                pass

    def _switch_nocheck(self):
        if self.view_previous:
            # If X.Opposite is used we don't know the stack order
            self.view_current.window.configure(stack_mode=X.Below)
            oldcur = self.view_current
            self.view_current = self.view_previous
            self.view_previous = oldcur
            self.view_current.focus()

    def switch(self):
        if not self.lock_switch.acquire(False):
            return
        try:
            for view in [self.view_current, self.view_previous]:
                if view and not view.win_alive():
                    view.launch()
            with self.lock_handler:
                self._switch_nocheck()
        finally:
            self.lock_switch.release()

    def switch2view(self, level):
        if level == LEVEL_NAME[self.view_current.props.level]:
            self.switch()
            self.switch()
        elif self.view_previous and level == LEVEL_NAME[self.view_previous.props.level]:
            self.switch()

# vim: set expandtab tabstop=4 softtabstop=4 shiftwidth=4:
