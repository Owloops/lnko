rockspec_format = "3.0"
package = "lnko"
version = "scm-1"

source = {
    url = "git+https://github.com/luanvil/lnko.git",
}

description = {
    summary = "Simple stow-like dotfile linker",
    homepage = "https://github.com/luanvil/lnko",
    license = "GPL-3.0",
}

dependencies = {
    "lua >= 5.1, < 5.5",
    "luafilesystem >= 1.8.0",
}

test_dependencies = {
    "busted",
}

build = {
    type = "builtin",
    modules = {
        ["lnko"] = "lnko/init.lua",
        ["lnko.fs"] = "lnko/fs.lua",
        ["lnko.plan"] = "lnko/plan.lua",
        ["lnko.tree"] = "lnko/tree.lua",
        ["lnko.output"] = "lnko/output.lua",
    },
    install = {
        bin = {
            ["lnko"] = "bin/lnko.lua",
        }
    },
}
