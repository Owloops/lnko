local lnko = require("lnko")
local fs = require("lnko.fs")
local plan = require("lnko.plan")
local json = require("lnko.json")

describe("lnko", function()
  local test_dir = "/tmp/lnko-test-" .. os.time() .. "-" .. math.random(10000)

  teardown(function()
    os.execute("rm -rf " .. test_dir)
  end)

  describe("plan", function()
    it("should create empty plan", function()
      local p = plan.new()
      assert.are.equal(0, #plan.get_tasks(p))
      assert.is_false(plan.has_conflicts(p))
    end)

    it("should add tasks to plan", function()
      local p = plan.new()
      plan.add_task(p, plan.ACTION_LINK, "/target/file", "/source/file")
      assert.are.equal(1, #plan.get_tasks(p))
    end)

    it("should track conflicts", function()
      local p = plan.new()
      plan.add_conflict(p, "/some/path", "test conflict")
      assert.is_true(plan.has_conflicts(p))
      assert.are.equal(1, #plan.get_conflicts(p))
    end)
  end)

  describe("status", function()
    it("should treat empty package as not linked", function()
      local source = test_dir .. "/status_empty_source"
      local target = test_dir .. "/status_empty_target"
      os.execute("mkdir -p " .. source .. "/empty_pkg")
      os.execute("mkdir -p " .. target)
      local p = lnko.plan_link(source, "empty_pkg", target, {})
      local tasks = plan.get_tasks(p)
      assert.are.equal(0, #tasks)
    end)

    it("should report occupied by sibling package", function()
      local source = test_dir .. "/status_sibling_source"
      local target = test_dir .. "/status_sibling_target"
      os.execute("mkdir -p " .. source .. "/host_a")
      os.execute("mkdir -p " .. source .. "/host_b")
      os.execute("mkdir -p " .. target)
      os.execute("echo a > " .. source .. "/host_a/.bashrc")
      os.execute("echo b > " .. source .. "/host_b/.bashrc")

      lnko.link_package(source, "host_a", target, { skip = true })

      local results = lnko.get_status(source, target)
      local by_name = {}
      for _, r in ipairs(results) do
        by_name[r.package] = r
      end
      assert.are.equal("ok", by_name["host_a"].status)
      assert.are.equal("occupied", by_name["host_b"].status)
    end)
  end)

  describe("json", function()
    it("should encode primitives and tables", function()
      assert.are.equal("null", json.encode(nil))
      assert.are.equal("true", json.encode(true))
      assert.are.equal('"a\\nb"', json.encode("a\nb"))
      assert.are.equal("[1,2]", json.encode({ 1, 2 }))
      assert.are.equal('{"a":1}', json.encode({ a = 1 }))
    end)
  end)

  describe("link", function()
    it("should plan link for package", function()
      local source = test_dir .. "/link_plan_source"
      local target = test_dir .. "/link_plan_target"
      os.execute("mkdir -p " .. source .. "/pkg/subdir")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'file1' > " .. source .. "/pkg/file1.txt")
      os.execute("echo 'file2' > " .. source .. "/pkg/subdir/file2.txt")

      local p = lnko.plan_link(source, "pkg", target, {})
      assert.is_false(plan.has_conflicts(p))
      local tasks = plan.get_tasks(p)
      assert.is_true(#tasks > 0)
    end)

    it("should link and unlink package", function()
      local source = test_dir .. "/link_unlink_source"
      local target = test_dir .. "/link_unlink_target"
      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'file1' > " .. source .. "/pkg/file1.txt")

      lnko.link_package(source, "pkg", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/file1.txt"))

      lnko.unlink_package(source, "pkg", target, {})
      assert.is_false(fs.exists(target .. "/file1.txt"))
    end)

    it("should have no tasks when re-linking already linked package", function()
      local source = test_dir .. "/relink_source"
      local target = test_dir .. "/relink_target"
      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'test' > " .. source .. "/pkg/file.txt")

      lnko.link_package(source, "pkg", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/file.txt"))

      local p = lnko.plan_link(source, "pkg", target, { skip = true })
      local tasks = plan.get_tasks(p)
      assert.are.equal(0, #tasks)
    end)
  end)

  describe("tree folding", function()
    it("should fold directory into single symlink", function()
      local source = test_dir .. "/fold_single_source"
      local target = test_dir .. "/fold_single_target"
      os.execute("mkdir -p " .. source .. "/pkg/.config/app")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'config' > " .. source .. "/pkg/.config/app/settings")

      lnko.link_package(source, "pkg", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/.config"))
    end)

    it("should unfold when adding package with shared directory", function()
      local source = test_dir .. "/fold_unfold_source"
      local target = test_dir .. "/fold_unfold_target"
      os.execute("mkdir -p " .. source .. "/pkg_a/.config/app_a")
      os.execute("mkdir -p " .. source .. "/pkg_b/.config/app_b")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'a' > " .. source .. "/pkg_a/.config/app_a/config")
      os.execute("echo 'b' > " .. source .. "/pkg_b/.config/app_b/config")

      lnko.link_package(source, "pkg_a", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/.config"))

      lnko.link_package(source, "pkg_b", target, { skip = true })
      assert.is_true(fs.is_directory(target .. "/.config"))
      assert.is_false(fs.is_symlink(target .. "/.config"))
      assert.is_true(fs.is_symlink(target .. "/.config/app_a"))
      assert.is_true(fs.is_symlink(target .. "/.config/app_b"))
    end)

    it("should link into existing directory", function()
      local source = test_dir .. "/existing_dir_source"
      local target = test_dir .. "/existing_dir_target"
      os.execute("mkdir -p " .. source .. "/pkg/lib")
      os.execute("mkdir -p " .. target .. "/lib")
      os.execute("echo 'file' > " .. source .. "/pkg/lib/file.txt")

      lnko.link_package(source, "pkg", target, { skip = true })
      assert.is_true(fs.is_directory(target .. "/lib"))
      assert.is_false(fs.is_symlink(target .. "/lib"))
      assert.is_true(fs.is_symlink(target .. "/lib/file.txt"))
    end)

    it("should unfold deeply with multiple packages (nvim-style)", function()
      local source = test_dir .. "/nvim_source"
      local target = test_dir .. "/nvim_target"
      os.execute("mkdir -p " .. source .. "/nvim/.config/nvim/lua/config")
      os.execute("mkdir -p " .. source .. "/lazy/.config/nvim/lua/plugins")
      os.execute("mkdir -p " .. source .. "/telescope/.config/nvim/lua/plugins/telescope")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'init' > " .. source .. "/nvim/.config/nvim/init.lua")
      os.execute("echo 'config' > " .. source .. "/nvim/.config/nvim/lua/config/init.lua")
      os.execute("echo 'lazy' > " .. source .. "/lazy/.config/nvim/lua/plugins/lazy.lua")
      os.execute("echo 'ts' > " .. source .. "/telescope/.config/nvim/lua/plugins/telescope/init.lua")

      lnko.link_package(source, "nvim", target, { skip = true })
      lnko.link_package(source, "lazy", target, { skip = true })
      lnko.link_package(source, "telescope", target, { skip = true })

      assert.is_true(fs.is_directory(target .. "/.config/nvim/lua/plugins"))
      assert.is_false(fs.is_symlink(target .. "/.config/nvim/lua/plugins"))
      assert.is_true(fs.is_symlink(target .. "/.config/nvim/lua/plugins/lazy.lua"))
      assert.is_true(fs.is_symlink(target .. "/.config/nvim/lua/plugins/telescope"))
    end)

    it("should not fold with no_folding option", function()
      local source = test_dir .. "/nofold_source"
      local target = test_dir .. "/nofold_target"
      os.execute("mkdir -p " .. source .. "/pkg/.config/app/nested")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'config' > " .. source .. "/pkg/.config/app/settings")
      os.execute("echo 'nested' > " .. source .. "/pkg/.config/app/nested/deep")

      lnko.link_package(source, "pkg", target, { skip = true, no_folding = true })

      assert.is_true(fs.is_directory(target .. "/.config"))
      assert.is_false(fs.is_symlink(target .. "/.config"))
      assert.is_true(fs.is_directory(target .. "/.config/app"))
      assert.is_false(fs.is_symlink(target .. "/.config/app"))
      assert.is_true(fs.is_directory(target .. "/.config/app/nested"))
      assert.is_false(fs.is_symlink(target .. "/.config/app/nested"))
      assert.is_true(fs.is_symlink(target .. "/.config/app/settings"))
      assert.is_true(fs.is_symlink(target .. "/.config/app/nested/deep"))
    end)
  end)

  describe("conflict detection", function()
    it("should skip conflict when linking from different source with skip option", function()
      local source1 = test_dir .. "/conflict_diff_source1"
      local source2 = test_dir .. "/conflict_diff_source2"
      local target = test_dir .. "/conflict_diff_target"

      os.execute("mkdir -p " .. source1 .. "/pkg")
      os.execute("mkdir -p " .. source2 .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'original' > " .. source1 .. "/pkg/file.txt")
      os.execute("echo 'different' > " .. source2 .. "/pkg/file.txt")

      lnko.link_package(source1, "pkg", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/file.txt"))

      local p = lnko.plan_link(source2, "pkg", target, { skip = true })
      local tasks = plan.get_tasks(p)
      assert.are.equal(0, #tasks)
      assert.is_true(fs.symlink_points_to(target .. "/file.txt", source1 .. "/pkg/file.txt"))
    end)

    it("should detect conflict with existing regular file", function()
      local source = test_dir .. "/conflict_file_source"
      local target = test_dir .. "/conflict_file_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'source' > " .. source .. "/pkg/file.txt")
      os.execute("echo 'existing' > " .. target .. "/file.txt")

      local p = lnko.plan_link(source, "pkg", target, { skip = true })
      local tasks = plan.get_tasks(p)
      assert.are.equal(0, #tasks)
      assert.is_false(fs.is_symlink(target .. "/file.txt"))
      assert.is_true(fs.exists(target .. "/file.txt"))
    end)

    it("should overwrite conflict with force option", function()
      local source = test_dir .. "/conflict_force_source"
      local target = test_dir .. "/conflict_force_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'new' > " .. source .. "/pkg/file.txt")
      os.execute("echo 'existing' > " .. target .. "/file.txt")

      lnko.link_package(source, "pkg", target, { force = true })
      assert.is_true(fs.is_symlink(target .. "/file.txt"))
      assert.is_true(fs.symlink_points_to(target .. "/file.txt", source .. "/pkg/file.txt"))
    end)

    it("should backup conflict with backup option", function()
      local source = test_dir .. "/conflict_backup_source"
      local target = test_dir .. "/conflict_backup_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'new' > " .. source .. "/pkg/file.txt")
      os.execute("echo 'existing' > " .. target .. "/file.txt")

      lnko.link_package(source, "pkg", target, { backup = true })
      assert.is_true(fs.is_symlink(target .. "/file.txt"))
      assert.is_true(fs.is_directory(target .. "/.lnko-backup"))
    end)
  end)

  describe("ignore patterns", function()
    it("should ignore files matching pattern", function()
      local source = test_dir .. "/ignore_source"
      local target = test_dir .. "/ignore_target"

      os.execute("mkdir -p " .. source .. "/pkg/.git/objects")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'file' > " .. source .. "/pkg/file.txt")
      os.execute("echo 'git' > " .. source .. "/pkg/.git/config")
      os.execute("echo 'readme' > " .. source .. "/pkg/README.md")

      lnko.link_package(source, "pkg", target, { ignore = { ".git", "README*" } })
      assert.is_true(fs.is_symlink(target .. "/file.txt"))
      assert.is_false(fs.exists(target .. "/.git"))
      assert.is_false(fs.exists(target .. "/README.md"))
    end)
  end)

  describe("partial operations", function()
    it("should unlink one package while preserving others", function()
      local source = test_dir .. "/partial_source"
      local target = test_dir .. "/partial_target"

      os.execute("mkdir -p " .. source .. "/pkg_a/.config/app_a")
      os.execute("mkdir -p " .. source .. "/pkg_b/.config/app_b")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'a' > " .. source .. "/pkg_a/.config/app_a/config")
      os.execute("echo 'b' > " .. source .. "/pkg_b/.config/app_b/config")

      lnko.link_package(source, "pkg_a", target, { skip = true })
      lnko.link_package(source, "pkg_b", target, { skip = true })

      lnko.unlink_package(source, "pkg_a", target, {})

      assert.is_false(fs.exists(target .. "/.config/app_a"))
      assert.is_true(fs.is_symlink(target .. "/.config/app_b"))
    end)
  end)

  describe("stow compatibility", function()
    it("should recognize existing stow-created symlinks", function()
      local source = test_dir .. "/stow_source"
      local target = test_dir .. "/stow_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'config' > " .. source .. "/pkg/file.txt")
      os.execute("cd " .. target .. " && ln -s ../stow_source/pkg/file.txt file.txt")

      local p = lnko.plan_link(source, "pkg", target, { skip = true })
      local tasks = plan.get_tasks(p)
      assert.are.equal(0, #tasks)
    end)
  end)

  describe("edge cases", function()
    it("should handle circular symlinks gracefully", function()
      local source = test_dir .. "/circular_source"
      local target = test_dir .. "/circular_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("ln -s loop " .. source .. "/pkg/loop")

      lnko.link_package(source, "pkg", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/loop"))
    end)

    it("should handle unicode filenames", function()
      local source = test_dir .. "/unicode_source"
      local target = test_dir .. "/unicode_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'test' > '" .. source .. "/pkg/файл.txt'")
      os.execute("echo 'test' > '" .. source .. "/pkg/文件.txt'")
      os.execute("echo 'test' > '" .. source .. "/pkg/αρχείο.txt'")

      lnko.link_package(source, "pkg", target, { skip = true })

      assert.is_true(fs.is_symlink(target .. "/файл.txt"))
      assert.is_true(fs.is_symlink(target .. "/文件.txt"))
      assert.is_true(fs.is_symlink(target .. "/αρχείο.txt"))
    end)

    it("should handle deep nested directories", function()
      local source = test_dir .. "/deep_source"
      local target = test_dir .. "/deep_target"

      os.execute("mkdir -p " .. source .. "/pkg/a/b/c/d/e/f/g/h")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'deep' > " .. source .. "/pkg/a/b/c/d/e/f/g/h/file.txt")

      lnko.link_package(source, "pkg", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/a"))

      lnko.unlink_package(source, "pkg", target, {})
      assert.is_false(fs.exists(target .. "/a"))
    end)

    it("should handle hidden files within packages", function()
      local source = test_dir .. "/hidden_source"
      local target = test_dir .. "/hidden_target"

      os.execute("mkdir -p " .. source .. "/pkg/.hidden_dir")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'hidden' > " .. source .. "/pkg/.hidden_file")
      os.execute("echo 'nested' > " .. source .. "/pkg/.hidden_dir/.nested")

      lnko.link_package(source, "pkg", target, { skip = true })

      assert.is_true(fs.is_symlink(target .. "/.hidden_file"))
      assert.is_true(fs.is_symlink(target .. "/.hidden_dir"))
    end)

    it("should handle symlinks pointing outside source", function()
      local source = test_dir .. "/external_source"
      local target = test_dir .. "/external_target"
      local external_file = test_dir .. "/external_file.txt"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'external' > " .. external_file)
      os.execute("ln -s " .. external_file .. " " .. source .. "/pkg/link_to_external")

      lnko.link_package(source, "pkg", target, { skip = true })

      assert.is_true(fs.is_symlink(target .. "/link_to_external"))
    end)

    it("should preserve internal symlinks in packages (lib.so pattern)", function()
      local source = test_dir .. "/libso_source"
      local target = test_dir .. "/libso_target"

      os.execute("mkdir -p " .. source .. "/pkg/lib")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'library' > " .. source .. "/pkg/lib/lib.so.1")
      os.execute("ln -s lib.so.1 " .. source .. "/pkg/lib/lib.so")

      lnko.link_package(source, "pkg", target, { skip = true })

      assert.is_true(fs.is_symlink(target .. "/lib"))
      assert.is_true(fs.exists(target .. "/lib/lib.so.1"))
      assert.is_true(fs.is_symlink(target .. "/lib/lib.so"))
      assert.are.equal("lib.so.1", fs.symlink_target(target .. "/lib/lib.so"))
    end)

    it("should handle relative source path", function()
      local base = test_dir .. "/relative_test"
      local source = base .. "/dotfiles"
      local target = base .. "/home"

      os.execute("mkdir -p " .. source .. "/bash")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'bashrc' > " .. source .. "/bash/.bashrc")

      lnko.link_package(source, "bash", target, { skip = true })

      assert.is_true(fs.is_symlink(target .. "/.bashrc"))
      assert.is_true(fs.symlink_points_to(target .. "/.bashrc", source .. "/bash/.bashrc"))
    end)

    it("should resolve symlinks in parent directories with realpath", function()
      local base = test_dir .. "/realpath_test"
      local real_dir = base .. "/var/home/user"
      local symlink_dir = base .. "/home/user"

      os.execute("mkdir -p " .. real_dir)
      os.execute("mkdir -p " .. base .. "/home")
      os.execute("ln -s " .. real_dir .. " " .. symlink_dir)

      assert.are.equal(real_dir, fs.realpath(symlink_dir))
      assert.are.equal(real_dir, fs.realpath(real_dir))
      assert.is_nil(fs.realpath(base .. "/nonexistent"))
    end)

    it("should recognize existing stow symlinks when home is symlinked", function()
      local base = test_dir .. "/stow_compat_test"
      local real_home = base .. "/var/home/user"
      local fake_home = base .. "/home/user"

      os.execute("mkdir -p " .. real_home .. "/dotfiles/pkg/.config/app")
      os.execute("mkdir -p " .. real_home .. "/.config")
      os.execute("mkdir -p " .. base .. "/home")
      os.execute("ln -s " .. real_home .. " " .. fake_home)
      os.execute("echo 'config' > " .. real_home .. "/dotfiles/pkg/.config/app/settings")
      os.execute("ln -s ../dotfiles/pkg/.config/app " .. real_home .. "/.config/app")

      local p = lnko.plan_link(fake_home .. "/dotfiles", "pkg", fake_home, { skip = true })
      assert.are.equal(0, #plan.get_tasks(p))
    end)

    it("should create working symlinks when source and target use mixed paths", function()
      local base = test_dir .. "/mixed_path_test"
      local real_home = base .. "/var/home/user"
      local fake_home = base .. "/home/user"

      os.execute("mkdir -p " .. real_home .. "/dotfiles/pkg/.config/app")
      os.execute("mkdir -p " .. real_home .. "/.config")
      os.execute("mkdir -p " .. base .. "/home")
      os.execute("ln -s " .. real_home .. " " .. fake_home)
      os.execute("echo 'testcontent' > " .. real_home .. "/dotfiles/pkg/.config/app/settings")

      local p = lnko.plan_link(real_home .. "/dotfiles", "pkg", fake_home, { skip = true })
      plan.execute(p, {})

      local f = io.open(real_home .. "/.config/app/settings", "r")
      assert.is_truthy(f, "symlink should be readable")
      local content = f:read("*a")
      f:close()
      assert.are.equal("testcontent\n", content)
    end)

    it("should plan but fail to execute on read-only target", function()
      local source = test_dir .. "/readonly_source"
      local target = test_dir .. "/readonly_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'file' > " .. source .. "/pkg/file.txt")

      local p = lnko.plan_link(source, "pkg", target, { skip = true })
      assert.are.equal(1, #plan.get_tasks(p))

      os.execute("chmod 555 " .. target)
      lnko.link_package(source, "pkg", target, { skip = true })
      os.execute("chmod 755 " .. target)

      assert.is_falsy(fs.is_symlink(target .. "/file.txt"))
    end)
  end)

  describe("orphan detection", function()
    it("should detect orphan symlinks when source is deleted", function()
      local source = test_dir .. "/orphan_source"
      local target = test_dir .. "/orphan_target"

      os.execute("mkdir -p " .. source .. "/pkg")
      os.execute("mkdir -p " .. target)
      os.execute("echo 'file' > " .. source .. "/pkg/file.txt")

      lnko.link_package(source, "pkg", target, { skip = true })
      assert.is_true(fs.is_symlink(target .. "/file.txt"))

      os.execute("rm " .. source .. "/pkg/file.txt")

      local orphans = lnko.find_orphans(source, target)
      assert.are.equal(1, #orphans)
      assert.are.equal(target .. "/file.txt", orphans[1].link)
    end)
  end)
end)
