# Apelin's terminal starts its shell with the project's toolchain first on
# PATH and names it in APELIN_TOOLCHAIN_BIN. A login shell's /etc/profile
# sets PATH anew, then reads this folder: put the toolchain back in front.
# Anywhere else the variable is unset and this does nothing.
if [ -n "${APELIN_TOOLCHAIN_BIN:-}" ] && [ -d "$APELIN_TOOLCHAIN_BIN" ]; then
    case ":$PATH:" in
        *":$APELIN_TOOLCHAIN_BIN:"*) ;;
        *) PATH="$APELIN_TOOLCHAIN_BIN:$PATH"; export PATH ;;
    esac
fi
