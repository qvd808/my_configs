#!/bin/bash

ln -rsf $(pwd)/nvim/ ~/.config/
ln -rsf $(pwd)/tmux_configs/.tmux.conf ~/.tmux.conf
tmux source ~/.tmux.conf
