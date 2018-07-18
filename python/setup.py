#!/usr/bin/env python
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2011-2018 ANSSI. All Rights Reserved.
#
# Distutils script for clip-menu-xdg

from distutils.core import setup

setup(name = 'clip-menu-xdg',
      version = '1.1.1',
      description = 'Viewer manipulation library',
      url = 'http://www.ssi.gouv.fr/',
      author = 'Mickaël Salaün',
      author_email = 'clipos@ssi.gouv.fr',
      packages = [
          'clip',
          'clip.viewmgr'
          ]
      )

# vim: set expandtab tabstop=4 softtabstop=4 shiftwidth=4:
