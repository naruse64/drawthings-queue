/*
 * dtq エージェントの入口。
 *
 * なぜバイナリが要るのか:
 *   macOS の TCC は「実行中のプロセスの実体」に対して許可を紐づける。
 *   シェルスクリプトを直接 launchd から起動すると、実体は /bin/bash
 *   （Apple の platform binary）になるため、スクリプトのパスをフルディスク
 *   アクセスに追加しても許可が attach しない。一覧には出るのに効かない。
 *
 *   そこで署名済み app バンドルのバイナリをエージェントの入口にする。
 *   TCC はこのバンドルを識別でき、fork した子（bash ワーカー）は
 *   responsible process としてこのバンドルの許可を継承する。
 *   ターミナルから実行したスクリプトがターミナルの権限で動くのと同じ仕組み。
 *
 * exec ではなく fork+wait にしているのは、exec するとプロセスの実体が
 * bash に置き換わって TCC 上の身元が失われてしまうため。親として生き続ける
 * ことでバンドルの身元を保つ。
 */
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile pid_t child_pid = 0;

/* launchd の停止指示を子に届ける。ここで転送しないと、親だけ死んで
   ワーカーが孤児として走り続ける（lockf を親に据えたときと同じ失敗）。 */
static void forward_signal(int sig) {
    if (child_pid > 0) {
        kill(child_pid, sig);
    }
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;

    const char *home = getenv("HOME");
    if (home == NULL) {
        fprintf(stderr, "dtq-agent: HOME が設定されていない\n");
        return 78;
    }

    char script[PATH_MAX];
    int n = snprintf(script, sizeof script,
                     "%s/Library/Application Support/dtq/app/bin/dtq-worker",
                     home);
    if (n < 0 || (size_t)n >= sizeof script) {
        fprintf(stderr, "dtq-agent: ワーカーのパスが長すぎる\n");
        return 78;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = forward_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    child_pid = fork();
    if (child_pid < 0) {
        perror("dtq-agent: fork");
        return 70;
    }
    if (child_pid == 0) {
        execl("/bin/bash", "bash", script, (char *)NULL);
        perror("dtq-agent: exec");
        _exit(127);
    }

    int status = 0;
    while (waitpid(child_pid, &status, 0) < 0) {
        if (errno != EINTR) {
            perror("dtq-agent: waitpid");
            return 70;
        }
    }

    /* 終了コードを launchd にそのまま見せる */
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 1;
}
