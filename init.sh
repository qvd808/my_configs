#!/bin/bash

ln -rsf ./nvim/ ~/.config/
ln -rsf ./tmux_configs/.tmux.conf ~/.tmux.conf
tmux source ~/.tmux.conf
