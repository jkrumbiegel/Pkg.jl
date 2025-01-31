# This file is a part of Julia. License is MIT: https://julialang.org/license

module REPLTests

using Pkg
using Pkg.Types: manifest_info, EnvCache, Context
import Pkg.Types.PkgError
using UUIDs
using Test
import LibGit2

include("utils.jl")

@testset "help" begin
    pkg"?"
    pkg"?  "
    pkg"?add"
    pkg"? add"
    pkg"?    add"
    pkg"help add"
    @test_throws PkgError pkg"helpadd"
end

@testset "generate args" begin
    @test_throws PkgError pkg"generate"
end

temp_pkg_dir() do project_path
    with_pkg_env(project_path; change_dir=true) do;
        pkg"generate HelloWorld"
        LibGit2.close((LibGit2.init(".")))
        cd("HelloWorld")
        with_current_env() do
            pkg"st"
            @eval using HelloWorld
            Base.invokelatest(HelloWorld.greet)
            @test isfile("Project.toml")
            Pkg.REPLMode.pkgstr("develop $(joinpath(@__DIR__, "test_packages", "PackageWithBuildSpecificTestDeps"))")
            Pkg.test("PackageWithBuildSpecificTestDeps")
        end

        @test_throws PkgError pkg"dev Example#blergh"

        @test_throws PkgError pkg"generate 2019Julia"
        pkg"generate Foo"
        pkg"dev Foo"
        mv(joinpath("Foo", "src", "Foo.jl"), joinpath("Foo", "src", "Foo2.jl"))
        @test_throws PkgError pkg"dev Foo"
        mv(joinpath("Foo", "src", "Foo2.jl"), joinpath("Foo", "src", "Foo.jl"))
        write(joinpath("Foo", "Project.toml"), """
            name = "Foo"
        """
        )
        @test_throws PkgError pkg"dev Foo"
        write(joinpath("Foo", "Project.toml"), """
            uuid = "b7b78b08-812d-11e8-33cd-11188e330cbe"
        """
        )
        @test_throws PkgError pkg"dev Foo"
    end
end

temp_pkg_dir(;rm=false) do project_path; cd(project_path) do;
    tmp_pkg_path = mktempdir()

    pkg"activate ."
    pkg"add Example@0.5"
    @test isinstalled(TEST_PKG)
    v = Pkg.dependencies()[TEST_PKG.uuid].version
    pkg"rm Example"
    pkg"add Example, Random"
    pkg"rm Example Random"
    pkg"add Example,Random"
    pkg"rm Example,Random"
    pkg"add Example#master"

    # Test upgrade --fixed doesn't change the tracking (https://github.com/JuliaLang/Pkg.jl/issues/434)
    entry = Pkg.Types.manifest_info(Context(), TEST_PKG.uuid)
    @test entry.repo.rev == "master"
    pkg"up --fixed"
    entry = Pkg.Types.manifest_info(Context(), TEST_PKG.uuid)
    @test entry.repo.rev == "master"

    pkg"test Example"
    @test isinstalled(TEST_PKG)
    @test Pkg.dependencies()[TEST_PKG.uuid].version > v
    pkg = "UnregisteredWithoutProject"
    p = git_init_package(tmp_pkg_path, joinpath(@__DIR__, "test_packages/$pkg"))
    Pkg.REPLMode.pkgstr("add $p; precompile")
    @eval import $(Symbol(pkg))
    @test first([info for (uuid, info) in Pkg.dependencies() if info.name == pkg]).version == v"0.0"
    Pkg.test("UnregisteredWithoutProject")

    pkg2 = "UnregisteredWithProject"
    pkg2_uuid = UUID("58262bb0-2073-11e8-3727-4fe182c12249")
    p2 = git_init_package(tmp_pkg_path, joinpath(@__DIR__, "test_packages/$pkg2"))
    Pkg.REPLMode.pkgstr("add $p2")
    Pkg.REPLMode.pkgstr("pin $pkg2")
    # FIXME: this confuses the precompile logic to know what is going on with the user
    # FIXME: why isn't this testing the Pkg after importing, rather than after freeing it
    #@eval import Example
    #@eval import $(Symbol(pkg2))
    @test Pkg.dependencies()[pkg2_uuid].version == v"0.1.0"
    Pkg.REPLMode.pkgstr("free $pkg2")
    @test_throws PkgError Pkg.REPLMode.pkgstr("free $pkg2")
    Pkg.test("UnregisteredWithProject")

    write(joinpath(p2, "Project.toml"), """
        name = "UnregisteredWithProject"
        uuid = "58262bb0-2073-11e8-3727-4fe182c12249"
        version = "0.2.0"
        """
    )
    LibGit2.with(LibGit2.GitRepo, p2) do repo
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, "bump version"; author = TEST_SIG, committer=TEST_SIG)
        pkg"update"
        @test Pkg.dependencies()[pkg2_uuid].version == v"0.2.0"
        Pkg.REPLMode.pkgstr("rm $pkg2")

        c = LibGit2.commit(repo, "empty commit"; author = TEST_SIG, committer=TEST_SIG)
        c_hash = LibGit2.GitHash(c)
        Pkg.REPLMode.pkgstr("add $p2#$c")
    end

    mktempdir() do tmp_dev_dir
    withenv("JULIA_PKG_DEVDIR" => tmp_dev_dir) do
        pkg"develop Example"

        # Copy the manifest + project and see that we can resolve it in a new environment
        # and get all the packages installed
        proj = read("Project.toml", String)
        manifest = read("Manifest.toml", String)
        cd_tempdir() do tmp
            old_depot = copy(DEPOT_PATH)
            try
                empty!(DEPOT_PATH)
                write("Project.toml", proj)
                write("Manifest.toml", manifest)
                mktempdir() do depot_dir
                    pushfirst!(DEPOT_PATH, depot_dir)
                    pkg"instantiate"
                    @test Pkg.dependencies()[pkg2_uuid].version == v"0.2.0"
                end
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, old_depot)
            end
        end # cd_tempdir
    end # withenv
    end # mktempdir
end # cd
end # temp_pkg_dir

# issue #904: Pkg.status within a git repo
temp_pkg_dir() do path
    pkg2 = "UnregisteredWithProject"
    p2 = git_init_package(path, joinpath(@__DIR__, "test_packages/$pkg2"))
    Pkg.activate(p2)
    Pkg.status() # should not throw
    Pkg.REPLMode.pkgstr("status") # should not throw
end

temp_pkg_dir() do project_path; cd(project_path) do
    mktempdir() do tmp
        mktempdir() do depot_dir
            old_depot = copy(DEPOT_PATH)
            try
                empty!(DEPOT_PATH)
                pushfirst!(DEPOT_PATH, depot_dir)
                withenv("JULIA_PKG_DEVDIR" => tmp) do
                    # Test an unregistered package
                    p1_path = joinpath(@__DIR__, "test_packages", "UnregisteredWithProject")
                    p2_path = joinpath(@__DIR__, "test_packages", "UnregisteredWithoutProject")
                    p1_new_path = joinpath(tmp, "UnregisteredWithProject")
                    p2_new_path = joinpath(tmp, "UnregisteredWithoutProject")
                    cp(p1_path, p1_new_path)
                    cp(p2_path, p2_new_path)
                    Pkg.REPLMode.pkgstr("develop $(p1_new_path)")
                    Pkg.REPLMode.pkgstr("develop $(p2_new_path)")
                    Pkg.REPLMode.pkgstr("build; precompile")
                    @test Base.find_package("UnregisteredWithProject") == joinpath(p1_new_path, "src", "UnregisteredWithProject.jl")
                    @test Base.find_package("UnregisteredWithoutProject") == joinpath(p2_new_path, "src", "UnregisteredWithoutProject.jl")
                    @test Pkg.dependencies()[UUID("58262bb0-2073-11e8-3727-4fe182c12249")].version == v"0.1.0"
                    @test Pkg.dependencies()[Pkg.Types.Context().env.project.deps["UnregisteredWithoutProject"]].version == v"0.0.0"
                    Pkg.test("UnregisteredWithoutProject")
                    Pkg.test("UnregisteredWithProject")
                end
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, old_depot)
            end
        end # withenv
    end # mktempdir
    # nested
    mktempdir() do other_dir
        mktempdir() do tmp;
            cd(tmp)
            pkg"generate HelloWorld"
            cd("HelloWorld") do
                with_current_env() do
                    uuid1 = Pkg.generate("SubModule1")["SubModule1"]
                    uuid2 = Pkg.generate("SubModule2")["SubModule2"]
                    pkg"develop SubModule1"
                    mkdir("tests")
                    cd("tests")
                    pkg"develop ../SubModule2"
                    @test Pkg.dependencies()[uuid1].version == v"0.1.0"
                    @test Pkg.dependencies()[uuid2].version == v"0.1.0"
                    # make sure paths to SubModule1 and SubModule2 are relative
                    manifest = Pkg.Types.Context().env.manifest
                    @test manifest[uuid1].path == "SubModule1"
                    @test manifest[uuid2].path == "SubModule2"
                end
            end
            cp("HelloWorld", joinpath(other_dir, "HelloWorld"))
            cd(joinpath(other_dir, "HelloWorld"))
            with_current_env() do
                # Check that these didn't generate absolute paths in the Manifest by copying
                # to another directory
                @test Base.find_package("SubModule1") == joinpath(pwd(), "SubModule1", "src", "SubModule1.jl")
                @test Base.find_package("SubModule2") == joinpath(pwd(), "SubModule2", "src", "SubModule2.jl")
            end
        end
    end
end # cd
end # temp_pkg_dir

# activate
temp_pkg_dir() do project_path
    cd_tempdir() do tmp
        path = pwd()
        pkg"activate ."
        @test Base.active_project() == joinpath(path, "Project.toml")
        # tests illegal names for shared environments
        @test_throws Pkg.Types.PkgError pkg"activate --shared ."
        @test_throws Pkg.Types.PkgError pkg"activate --shared ./Foo"
        @test_throws Pkg.Types.PkgError pkg"activate --shared Foo/Bar"
        @test_throws Pkg.Types.PkgError pkg"activate --shared ../Bar"
        # check that those didn't change te enviroment
        @test Base.active_project() == joinpath(path, "Project.toml")
        mkdir("Foo")
        cd(mkdir("modules")) do
            pkg"generate Foo"
        end
        pkg"develop modules/Foo"
        pkg"activate Foo" # activate path Foo over deps Foo
        @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
        pkg"activate ."
        #=@test_logs (:info, r"activating new environment at ")))=# pkg"activate --shared Foo" # activate shared Foo
        @test Base.active_project() == joinpath(Pkg.envdir(), "Foo", "Project.toml")
        pkg"activate ."
        rm("Foo"; force=true, recursive=true)
        pkg"activate Foo" # activate path from developed Foo
        @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
        pkg"activate ."
        #=@test_logs (:info, r"activating new environment at ")=# pkg"activate ./Foo" # activate empty directory Foo (sidestep the developed Foo)
        @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
        pkg"activate ."
        #=@test_logs (:info, r"activating new environment at ")=# pkg"activate Bar" # activate empty directory Bar
        @test Base.active_project() == joinpath(path, "Bar", "Project.toml")
        pkg"activate ."
        pkg"add Example" # non-deved deps should not be activated
        #=@test_logs (:info, r"activating new environment at ")=# pkg"activate Example"
        @test Base.active_project() == joinpath(path, "Example", "Project.toml")
        pkg"activate ."
        cd(mkdir("tests"))
        pkg"activate Foo" # activate developed Foo from another directory
        @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
        tmpdepot = mktempdir(tmp)
        tmpdir = mkpath(joinpath(tmpdepot, "environments", "Foo"))
        push!(Base.DEPOT_PATH, tmpdepot)
        pkg"activate --shared Foo" # activate existing shared Foo
        @test Base.active_project() == joinpath(tmpdir, "Project.toml")
        pop!(Base.DEPOT_PATH)
        pkg"activate" # activate home project
        @test Base.ACTIVE_PROJECT[] === nothing
        # expansion of ~
        if !Sys.iswindows()
            pkg"activate ~/Foo"
            @test Base.active_project() == joinpath(homedir(), "Foo", "Project.toml")
        end
    end
end

# test relative dev paths (#490)
cd_tempdir() do tmp
    uuid1 = Pkg.generate("HelloWorld")["HelloWorld"]
    cd("HelloWorld")
    uuid2 = Pkg.generate("SubModule")["SubModule"]
    cd(mkdir("tests"))
    pkg"activate ."
    pkg"develop .." # HelloWorld
    pkg"develop ../SubModule"
    @test Pkg.dependencies()[uuid1].version == v"0.1.0"
    @test Pkg.dependencies()[uuid2].version == v"0.1.0"
    manifest = Pkg.Types.Context().env.manifest
    @test manifest[uuid1].path == ".."
    @test manifest[uuid2].path == joinpath("..", "SubModule")
end

# path should not be relative when devdir() happens to be in project
# unless user used dev --local.
temp_pkg_dir() do depot
    cd_tempdir() do tmp
        uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # Example
        pkg"activate ."
        withenv("JULIA_PKG_DEVDIR" => joinpath(pwd(), "dev")) do
            pkg"dev Example"
            @test manifest_info(Context(), uuid).path == joinpath(pwd(), "dev", "Example")
            pkg"dev --shared Example"
            @test manifest_info(Context(), uuid).path == joinpath(pwd(), "dev", "Example")
            pkg"dev --local Example"
            @test manifest_info(Context(), uuid).path == joinpath("dev", "Example")
        end
    end
end

# test relative dev paths (#490) without existing Project.toml
temp_pkg_dir() do depot; cd_tempdir() do tmp
    pkg"activate NonExistent"
    uuid= nothing
    withenv("USER" => "Test User") do
        uuid = Pkg.generate("Foo")["Foo"]
    end
    # this dev should not error even if NonExistent/Project.toml file is non-existent
    @test !isdir("NonExistent")
    pkg"dev Foo"
    manifest = Pkg.Types.Context().env.manifest
    @test manifest[uuid].path == joinpath("..", "Foo")
end end

@testset "develop with `--shared` and `--local" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmp
        uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # Example
        pkg"activate ."
        pkg"develop Example" # test default
        @test manifest_info(Context(), uuid).path == joinpath(Pkg.devdir(), "Example")
        pkg"develop --shared Example"
        @test manifest_info(Context(), uuid).path == joinpath(Pkg.devdir(), "Example")
        pkg"develop --local Example"
        @test manifest_info(Context(), uuid).path == joinpath("dev", "Example")
    end end
end

test_complete(s) = Pkg.REPLMode.completions(s, lastindex(s))
apply_completion(str) = begin
    c, r, s = test_complete(str)
    str[1:prevind(str, first(r))]*first(c)
end

# Autocompletions
temp_pkg_dir() do project_path; cd(project_path) do
    @testset "tab completion" begin
        pkg"registry add General" # instantiate the `General` registry to complete remote package names
        pkg"activate ."
        c, r = test_complete("add Exam")
        @test "Example" in c
        c, r = test_complete("rm Exam")
        @test isempty(c)
        Pkg.REPLMode.pkgstr("develop $(joinpath(@__DIR__, "test_packages", "RequireDependency"))")

        c, r = test_complete("rm RequireDep")
        @test "RequireDependency" in c
        c, r = test_complete("rm -p RequireDep")
        @test "RequireDependency" in c
        c, r = test_complete("rm --project RequireDep")
        @test "RequireDependency" in c
        c, r = test_complete("rm Exam")
        @test isempty(c)
        c, r = test_complete("rm -p Exam")
        @test isempty(c)
        c, r = test_complete("rm --project Exam")
        @test isempty(c)

        c, r = test_complete("rm -m RequireDep")
        @test "RequireDependency" in c
        c, r = test_complete("rm --manifest RequireDep")
        @test "RequireDependency" in c
        c, r = test_complete("rm -m Exam")
        @test "Example" in c
        c, r = test_complete("rm --manifest Exam")
        @test "Example" in c

        c, r = test_complete("rm RequireDep")
        @test "RequireDependency" in c
        c, r = test_complete("rm Exam")
        @test isempty(c)
        c, r = test_complete("rm -m Exam")
        c, r = test_complete("rm -m Exam")
        @test "Example" in c

        pkg"add Example"
        c, r = test_complete("rm Exam")
        @test "Example" in c
        c, r = test_complete("up --man")
        @test "--manifest" in c
        c, r = test_complete("rem")
        @test "remove" in c
        @test apply_completion("rm E") == "rm Example"
        @test apply_completion("add Exampl") == "add Example"

        c, r = test_complete("preview r")
        @test "remove" in c
        c, r = test_complete("help r")
        @test "remove" in c
        @test !("rm" in c)

        # stdlibs
        c, r = test_complete("add Stat")
        @test "Statistics" in c
        c, r = test_complete("add Lib")
        @test "LibGit2" in c
        c, r = test_complete("add REPL")
        @test "REPL" in c

        # upper bounded
        c, r = test_complete("add Chu")
        @test !("Chunks" in c)

        # local paths
        mkpath("testdir/foo/bar")
        c, r = test_complete("add ")
        @test Sys.iswindows() ? ("testdir\\\\" in c) : ("testdir/" in c)
        @test "Example" in c
        @test apply_completion("add tes") == (Sys.iswindows() ? "add testdir\\\\" : "add testdir/")
        @test apply_completion("add ./tes") == (Sys.iswindows() ? "add ./testdir\\\\" : "add ./testdir/")
        c, r = test_complete("dev ./")
        @test (Sys.iswindows() ? ("testdir\\\\" in c) : ("testdir/" in c))

        # complete subdirs
        c, r = test_complete("add testdir/f")
        @test Sys.iswindows() ? ("foo\\\\" in c) : ("foo/" in c)
        @test apply_completion("add testdir/f") == (Sys.iswindows() ? "add testdir/foo\\\\" : "add testdir/foo/")
        # dont complete files
        touch("README.md")
        c, r = test_complete("add RE")
        @test !("README.md" in c)

        # activate
        pkg"activate --shared FooBar"
        pkg"add Example"
        pkg"activate ."
        c, r = test_complete("activate --shared ")
        @test "FooBar" in c
    end # testset
end end

temp_pkg_dir() do project_path; cd(project_path) do
    mktempdir() do tmp
        cp(joinpath(@__DIR__, "test_packages", "BigProject"), joinpath(tmp, "BigProject"))
        cd(joinpath(tmp, "BigProject"))
        with_current_env() do
            # the command below also tests multiline input
            pkg"""
                dev RecursiveDep2
                dev RecursiveDep
                dev SubModule
                dev SubModule2
                add Random
                add Example
                add JSON
                build
            """
            @eval using BigProject
            pkg"build BigProject"
            @test_throws PkgError pkg"add BigProject"
            # the command below also tests multiline input
            Pkg.REPLMode.pkgstr("""
                test SubModule
                test SubModule2
                test BigProject
                test
                """)
            json_uuid = Pkg.project().dependencies["JSON"]
            current_json = Pkg.dependencies()[json_uuid].version
            old_project = read("Project.toml", String)
            open("Project.toml"; append=true) do io
                print(io, """

                [compat]
                JSON = "0.18.0"
                """
                )
            end
            pkg"up"
            @test Pkg.dependencies()[json_uuid].version.minor == 18
            write("Project.toml", old_project)
            pkg"up"
            @test Pkg.dependencies()[json_uuid].version == current_json
        end
    end
end; end

temp_pkg_dir() do project_path
    cd(project_path) do
        @testset "add/remove using quoted local path" begin
            # utils
            setup_package(parent_dir, pkg_name) = begin
                mkdir(parent_dir)
                cd(parent_dir) do
                    withenv("USER" => "Test User") do
                        Pkg.generate(pkg_name)
                    end
                    cd(pkg_name) do
                        git_init_and_commit(joinpath(project_path, parent_dir, pkg_name))
                    end #cd pkg_name
                end # cd parent_dir
            end

            # extract uuid from a Project.toml file
            extract_uuid(toml_path) = begin
                uuid = ""
                for line in eachline(toml_path)
                    m = match(r"uuid = \"(.+)\"", line)
                    if m !== nothing
                        uuid = m.captures[1]
                        break
                    end
                end
                return uuid
            end

            # testing local dir with space in name
            dir_name = "space dir"
            pkg_name = "WeirdName77"
            setup_package(dir_name, pkg_name)
            uuid = extract_uuid("$dir_name/$pkg_name/Project.toml")
            Pkg.REPLMode.pkgstr("add \"$dir_name/$pkg_name\"")
            @test isinstalled((name=pkg_name, uuid = UUID(uuid)))
            Pkg.REPLMode.pkgstr("remove \"$pkg_name\"")
            @test !isinstalled((name=pkg_name, uuid = UUID(uuid)))

            # testing dir name with significant characters
            dir_name = "some@d;ir#"
            pkg_name = "WeirdName77"
            setup_package(dir_name, pkg_name)
            uuid = extract_uuid("$dir_name/$pkg_name/Project.toml")
            Pkg.REPLMode.pkgstr("add \"$dir_name/$pkg_name\"")
            @test isinstalled((name=pkg_name, uuid = UUID(uuid)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name'")
            @test !isinstalled((name=pkg_name, uuid = UUID(uuid)))

            # more complicated input
            ## pkg1
            dir1 = "two space dir"
            pkg_name1 = "name1"
            setup_package(dir1, pkg_name1)
            uuid1 = extract_uuid("$dir1/$pkg_name1/Project.toml")

            ## pkg2
            dir2 = "two'quote'dir"
            pkg_name2 = "name2"
            setup_package(dir2, pkg_name2)
            uuid2 = extract_uuid("$dir2/$pkg_name2/Project.toml")

            Pkg.REPLMode.pkgstr("add '$dir1/$pkg_name1' \"$dir2/$pkg_name2\"")
            @test isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test isinstalled((name=pkg_name2, uuid = UUID(uuid2)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name1' $pkg_name2")
            @test !isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test !isinstalled((name=pkg_name2, uuid = UUID(uuid2)))

            Pkg.REPLMode.pkgstr("add '$dir1/$pkg_name1' \"$dir2/$pkg_name2\"")
            @test isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test isinstalled((name=pkg_name2, uuid = UUID(uuid2)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name1' \"$pkg_name2\"")
            @test !isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test !isinstalled((name=pkg_name2, uuid = UUID(uuid2)))
        end
    end
end

@testset "unit test `parse_package_identifier`" begin; cd(mktempdir()) do
    name = "FooBar"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    url = "https://github.com/JuliaLang/Example.jl"
    path = "./Foobar"; mkdir("Foobar")
    # valid input
    pkg = Pkg.REPLMode.parse_package_identifier(name)
    @test pkg.name == name
    pkg = Pkg.REPLMode.parse_package_identifier(uuid)
    @test pkg.uuid == UUID(uuid)
    pkg = Pkg.REPLMode.parse_package_identifier("$name=$uuid")
    @test (pkg.name == name) && (pkg.uuid == UUID(uuid))
    pkg = Pkg.REPLMode.parse_package_identifier(url; add_or_develop=true)
    @test pkg.repo.url == url
    pkg = Pkg.REPLMode.parse_package_identifier(path; add_or_develop=true)
    @test pkg.repo.url == path
    # expansion of ~
    if !Sys.iswindows()
        tildepath = "~/Foobaz"
        try
            mkdir(expanduser(tildepath))
            pkg = Pkg.REPLMode.parse_package_identifier(tildepath; add_or_develop=true)
            @test pkg.repo.url == expanduser(tildepath)
        finally
            rm(expanduser(tildepath); force = true)
        end
    end
    # errors
    @test_throws PkgError Pkg.REPLMode.parse_package_identifier(url)
    @test_throws PkgError Pkg.REPLMode.parse_package_identifier(path)
end end

@testset "parse package url win" begin
    @test typeof(Pkg.REPLMode.parse_package_identifier("https://github.com/abc/ABC.jl";
                                                       add_or_develop=true)) == Pkg.Types.PackageSpec
end

@testset "unit test for REPLMode.promptf" begin
    function set_name(projfile_path, newname)
        sleep(1.1)
        project = Pkg.TOML.parsefile(projfile_path)
        project["name"] = newname
        open(projfile_path, "w") do io
            Pkg.TOML.print(io, project)
        end
    end

    with_temp_env("SomeEnv") do
        @test Pkg.REPLMode.promptf() == "(SomeEnv) pkg> "
    end

    env_name = "Test2"
    with_temp_env(env_name) do env_path
        projfile_path = joinpath(env_path, "Project.toml")
        @test Pkg.REPLMode.promptf() == "($env_name) pkg> "

        newname = "NewName"
        set_name(projfile_path, newname)
        @test Pkg.REPLMode.promptf() == "($newname) pkg> "
        cd(env_path) do
            @test Pkg.REPLMode.promptf() == "($newname) pkg> "
        end
        @test Pkg.REPLMode.promptf() == "($newname) pkg> "

        newname = "NewNameII"
        set_name(projfile_path, newname)
        cd(env_path) do
            @test Pkg.REPLMode.promptf() == "($newname) pkg> "
        end
        @test Pkg.REPLMode.promptf() == "($newname) pkg> "
    end
end

@testset "Argument order" begin
    with_temp_env() do
        @test_throws PkgError Pkg.REPLMode.pkgstr("add FooBar Example#foobar#foobar")
        @test_throws PkgError Pkg.REPLMode.pkgstr("up Example#foobar@0.0.0")
        @test_throws PkgError Pkg.REPLMode.pkgstr("pin Example@0.0.0@0.0.1")
        @test_throws PkgError Pkg.REPLMode.pkgstr("up #foobar")
        @test_throws PkgError Pkg.REPLMode.pkgstr("add @0.0.1")
    end
end

@testset "`do_generate!` error paths" begin
    with_temp_env() do
        @test_throws PkgError Pkg.REPLMode.pkgstr("generate Example Example2")
        @test_throws PkgError Pkg.REPLMode.pkgstr("generate")
    end
end

@testset "`parse_option` unit tests" begin
    opt = Pkg.REPLMode.parse_option("-x")
    @test opt.val == "x"
    @test opt.argument === nothing
    opt = Pkg.REPLMode.parse_option("--hello")
    @test opt.val == "hello"
    @test opt.argument === nothing
    opt = Pkg.REPLMode.parse_option("--env=some")
    @test opt.val == "env"
    @test opt.argument == "some"
end

@testset "`parse` integration tests" begin
    QString = Pkg.REPLMode.QString
    @test isempty(Pkg.REPLMode.parse(""))

    statement = Pkg.REPLMode.parse("up")[1]
    @test statement.spec.kind == Pkg.REPLMode.CMD_UP
    @test isempty(statement.options)
    @test isempty(statement.arguments)
    @test statement.preview == false

    statement = Pkg.REPLMode.parse("dev Example")[1]
    @test statement.spec.kind == Pkg.REPLMode.CMD_DEVELOP
    @test isempty(statement.options)
    @test statement.arguments == [QString("Example", false)]
    @test statement.preview == false

    statement = Pkg.REPLMode.parse("dev Example#foo #bar")[1]
    @test statement.spec.kind == Pkg.REPLMode.CMD_DEVELOP
    @test isempty(statement.options)
    @test statement.arguments == [QString("Example#foo", false),
                                  QString("#bar", false)]
    @test statement.preview == false

    statement = Pkg.REPLMode.parse("dev Example#foo Example@v0.0.1")[1]
    @test statement.spec.kind == Pkg.REPLMode.CMD_DEVELOP
    @test isempty(statement.options)
    @test statement.arguments == [QString("Example#foo", false),
                                  QString("Example@v0.0.1", false)]
    @test statement.preview == false

    statement = Pkg.REPLMode.parse("add --first --second arg1")[1]
    @test statement.spec.kind == Pkg.REPLMode.CMD_ADD
    @test statement.options == map(Pkg.REPLMode.parse_option, ["--first", "--second"])
    @test statement.arguments == [QString("arg1", false)]
    @test statement.preview == false

    statements = Pkg.REPLMode.parse("preview add --first -o arg1; pin -x -a arg0 Example")
    @test statements[1].spec.kind == Pkg.REPLMode.CMD_ADD
    @test statements[1].preview == true
    @test statements[1].options == map(Pkg.REPLMode.parse_option, ["--first", "-o"])
    @test statements[1].arguments == [QString("arg1", false)]
    @test statements[2].spec.kind == Pkg.REPLMode.CMD_PIN
    @test statements[2].preview == false
    @test statements[2].options == map(Pkg.REPLMode.parse_option, ["-x", "-a"])
    @test statements[2].arguments == [QString("arg0", false), QString("Example", false)]

    statements = Pkg.REPLMode.parse("up; pin --first; dev")
    @test statements[1].spec.kind == Pkg.REPLMode.CMD_UP
    @test statements[1].preview == false
    @test isempty(statements[1].options)
    @test isempty(statements[1].arguments)
    @test statements[2].spec.kind == Pkg.REPLMode.CMD_PIN
    @test statements[2].preview == false
    @test statements[2].options == map(Pkg.REPLMode.parse_option, ["--first"])
    @test isempty(statements[2].arguments)
    @test statements[3].spec.kind == Pkg.REPLMode.CMD_DEVELOP
    @test statements[3].preview == false
    @test isempty(statements[3].options)
    @test isempty(statements[3].arguments)
end

@testset "argument count errors" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("activate one two")
        @test_throws PkgError Pkg.REPLMode.pkgstr("activate one two three")
        @test_throws PkgError Pkg.REPLMode.pkgstr("precompile Example")
    end
    end
    end
end

@testset "invalid options" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("rm --minor Example")
        @test_throws PkgError Pkg.REPLMode.pkgstr("pin --project Example")
    end
    end
    end
end

@testset "Argument order" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("add FooBar Example#foobar#foobar")
        @test_throws PkgError Pkg.REPLMode.pkgstr("up Example#foobar@0.0.0")
        @test_throws PkgError Pkg.REPLMode.pkgstr("pin Example@0.0.0@0.0.1")
        @test_throws PkgError Pkg.REPLMode.pkgstr("up #foobar")
        @test_throws PkgError Pkg.REPLMode.pkgstr("add @0.0.1")
    end
    end
    end
end

@testset "conflicting options" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("up --major --minor")
        @test_throws PkgError Pkg.REPLMode.pkgstr("rm --project --manifest")
    end
    end
    end
end

@testset "gc" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("gc --project")
        @test_throws PkgError Pkg.REPLMode.pkgstr("gc --minor")
        @test_throws PkgError Pkg.REPLMode.pkgstr("gc Example")
        Pkg.REPLMode.pkgstr("gc")
    end
    end
    end
end

@testset "precompile" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("precompile --project")
        @test_throws PkgError Pkg.REPLMode.pkgstr("precompile Example")
        Pkg.REPLMode.pkgstr("precompile")
        Pkg.precompile()
    end
    end
    end
end

@testset "generate" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("generate --major Example")
        @test_throws PkgError Pkg.REPLMode.pkgstr("generate --foobar Example")
        @test_throws PkgError Pkg.REPLMode.pkgstr("generate Example1 Example2")
        Pkg.REPLMode.pkgstr("generate Example")
    end
    end
    end
end

@testset "test" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        Pkg.add("Example")
        @test_throws PkgError Pkg.REPLMode.pkgstr("test --project Example")
        Pkg.REPLMode.pkgstr("test --coverage Example")
        Pkg.REPLMode.pkgstr("test Example")
    end
    end
    end
end

@testset "build" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("build --project")
        @test_throws PkgError Pkg.REPLMode.pkgstr("build --minor")
    end
    end
    end
end

@testset "free" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("free --project")
        @test_throws PkgError Pkg.REPLMode.pkgstr("free --major")
    end
    end
    end
end

@testset "tests for api opts" begin
    specs = Pkg.REPLMode.OptionSpecs(Pkg.REPLMode.OptionDeclaration[
        [:name => "project", :short_name => "p", :api => :mode => Pkg.Types.PKGMODE_PROJECT],
        [:name => "manifest", :short_name => "m", :api => :mode => Pkg.Types.PKGMODE_MANIFEST],
        [:name => "major", :api => :level => Pkg.Types.UPLEVEL_MAJOR],
        [:name => "minor", :api => :level => Pkg.Types.UPLEVEL_MINOR],
        [:name => "patch", :api => :level => Pkg.Types.UPLEVEL_PATCH],
        [:name => "fixed", :api => :level => Pkg.Types.UPLEVEL_FIXED],
        [:name => "rawnum", :takes_arg => true, :api => :num => identity],
        [:name => "plus", :takes_arg => true, :api => :num => x->parse(Int,x)+1],
    ])

    api_opts = Pkg.REPLMode.APIOptions([
        Pkg.REPLMode.Option("manifest"),
        Pkg.REPLMode.Option("patch"),
        Pkg.REPLMode.Option("rawnum", "5"),
    ], specs)

    @test get(api_opts,:foo,nothing) === nothing
    @test get(api_opts,:mode,nothing) == Pkg.Types.PKGMODE_MANIFEST
    @test get(api_opts,:level,nothing) == Pkg.Types.UPLEVEL_PATCH
    @test get(api_opts,:num,nothing) == "5"

    api_opts = Pkg.REPLMode.APIOptions([
        Pkg.REPLMode.Option("project"),
        Pkg.REPLMode.Option("patch"),
        Pkg.REPLMode.Option("plus", "5"),
    ], specs)

    @test get(api_opts,:mode,nothing) == Pkg.Types.PKGMODE_PROJECT
    @test get(api_opts,:level,nothing) == Pkg.Types.UPLEVEL_PATCH
    @test get(api_opts,:num,nothing) == 6
end

@testset "activate" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        mkdir("Foo")
        pkg"activate"
        default = Base.active_project()
        pkg"activate Foo"
        @test Base.active_project() == joinpath(pwd(), "Foo", "Project.toml")
        pkg"activate"
        @test Base.active_project() == default
    end end end
end

@testset "status" begin
    temp_pkg_dir() do project_path
        pkg"""
        add Example Random
        status
        status -m
        status Example
        status Example=7876af07-990d-54b4-ab0e-23690620f79a
        status 7876af07-990d-54b4-ab0e-23690620f79a
        status Example Random
        status -m Example
        """
        # --diff option
        @test_logs (:warn, r"diff option only available") pkg"status --diff"
        @test_logs (:warn, r"diff option only available") pkg"status -d"
        git_init_and_commit(project_path)
        @test_logs () pkg"status --diff"
        @test_logs () pkg"status -d"
    end
end

@testset "subcommands" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do
        Pkg.REPLMode.pkg"package add Example"
        @test isinstalled(TEST_PKG)
        Pkg.REPLMode.pkg"package rm Example"
        @test !isinstalled(TEST_PKG)
    end end end
end

@testset "preview" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        pkg"add Example"
        pkg"preview rm Example"
        @test isinstalled(TEST_PKG)
        pkg"rm Example"
        pkg"preview add Example"
        @test !isinstalled(TEST_PKG)
    end end end
end

@testset "`lex` unit tests" begin
    qwords = Pkg.REPLMode.lex("\"Don't\" forget to '\"test\"'")
    @test  qwords[1].isquoted
    @test  qwords[1].raw == "Don't"
    @test !qwords[2].isquoted
    @test  qwords[2].raw == "forget"
    @test !qwords[3].isquoted
    @test  qwords[3].raw == "to"
    @test  qwords[4].isquoted
    @test  qwords[4].raw == "\"test\""
    @test_throws PkgError Pkg.REPLMode.lex("Don't")
    @test_throws PkgError Pkg.REPLMode.lex("Unterminated \"quot")
end

@testset "argument kinds" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws PkgError pkg"pin Example#foo"
        @test_throws PkgError pkg"test Example#foo"
        @test_throws PkgError pkg"test Example@v0.0.1"
    end end end
end

@testset "smoke test `instantiate --verbose`" begin
    temp_pkg_dir() do project_path
        Pkg.activate(project_path)
        Pkg.instantiate(verbose=true)
        pkg"instantiate --verbose"
        pkg"instantiate -v"
    end
end

end # module
