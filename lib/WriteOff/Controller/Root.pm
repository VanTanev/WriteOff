package WriteOff::Controller::Root;
use Moose;
use namespace::autoclean;
no warnings "uninitialized";

BEGIN { extends 'Catalyst::Controller' }
with 'Catalyst::TraitFor::Controller::reCAPTCHA';

__PACKAGE__->config(namespace => '');

=head1 NAME

WriteOff::Controller::Root - Root Controller for WriteOff

=head1 METHODS

=head2 auto

Logs the request.

Detaches to index if the request is POST with a differing origin.

=cut

sub auto :Private {
	my ( $self, $c ) = @_;
	
	my $so = $c->req->uri->host eq eval { URI->new( $c->req->referer )->host };
	
	$c->log->info( sprintf "Request: %s - %s (%s) - %s" . ( $so ? "" : " - %s" ), 
		$c->req->method, 
		$c->req->address,
		( $c->user ? $c->user->get('username') : 'guest' ),
		$c->req->uri->path,
		$c->req->referer || 'no referer',
	) unless $so && $c->stash->{no_log};
	
	$c->detach('index') if !$so && $c->req->method eq 'POST';
	
	$c->stash->{now} = $c->model('DB::Event')->now_dt;
}

=head2 index

Lists all active events.

=cut

sub index :Path :Args(0) {
	my ( $self, $c ) = @_;
	
	$c->stash->{events} = $c->model('DB::Event')->active;
	
	$c->stash->{title} = 'Active Events';
	$c->stash->{template} = 'index.tt';
}

=head2 archive

Lists all old events.

=cut

sub archive :Local :Args(0) {
	my ( $self, $c ) = @_;
	
	$c->stash->{events} = $c->model('DB::Event')->old;
	
	$c->stash->{title} = 'Event Archive';
	$c->stash->{template} = 'index.tt';
}

=head2 faq

Frequently Asked Questions page

=cut

sub faq :Local :Args(0) {
	my ( $self, $c ) = @_;
	
	$c->stash->{title} = 'FAQ';
	$c->stash->{template} = 'faq.tt';
}

=head2 default

Standard 404 error page

=cut

sub default :Path {
	my ( $self, $c ) = @_;
	
	$c->stash->{title} = [ '404', 'File Not Found' ],
	$c->stash->{template} = '404.tt';
	$c->res->status(404);
}

=head2 forbidden

Standard 403 page

=cut

sub forbidden :Private {
	my ( $self, $c, $msg ) = @_;
	
	$c->stash->{forbidden_msg} = $msg // 'Access denied';
	
	$c->stash->{title} = [ '403', 'Forbidden' ],
	$c->stash->{template} = '403.tt';
	$c->res->status(403);
}

=head2 error

Error page

=cut

sub error :Private {
	my ( $self, $c, $msg ) = @_;
	
	$c->stash->{error} = $msg // 'Something went wrong';
	
	$c->stash->{title} = [ 'Error' ],
	$c->stash->{template} = 'error.tt';
	$c->res->status(404);
}

=head2 tos

Terms of Service page

=cut

sub tos :Local :Args(0) {
	my ( $self, $c ) = @_;
	
	$c->stash->{title} = 'Terms of Service';
	$c->stash->{template} = 'tos.tt';
}

=head2 contact

Allow users to contact the admin or developer.

=cut

sub contact :Local :Args(0) {
	my ( $self, $c ) = @_;
	
	if( $c->user ) {
	
		$c->stash->{fillform}{from} = $c->user->username_and_email;
		
		my $staff = $c->stash->{staff} = [
			sprintf( "%s <%s>", 'Admin', $c->config->{AdminEmail} ),
			sprintf( "%s <%s>", 'Developer', $c->config->{DevEmail} ),
		];
		
		my $subjects = $c->stash->{subjects} = [ 
			'Event Idea', 
			'Feature Request', 
			'Bug Report',
			'Rule Breakers',
			'Other',
		];
		
		if( $c->req->method eq 'POST' ) {
		
			$c->form(
				to => [ 'NOT_BLANK', [ 'IN_ARRAY', @$staff ] ],
				subject => [ 'NOT_BLANK', [ 'IN_ARRAY', @$subjects ] ],
				message => [ 'NOT_BLANK' ],
			);
			
			$c->forward('send_contact_email') if !$c->form->has_error;
		}
	}
	
	$c->stash->{title} = 'Contact Us';
	$c->stash->{template} = 'contact.tt';
}

sub send_contact_email :Private {
	my ( $self, $c ) = @_;
	
	for my $recipient ( $c->form->valid('to'), $c->user->username_and_email ) {
		
		$c->stash->{email} = {
			to           => $recipient,
			from         => $c->mailfrom,
			subject      => $c->config->{name} . " - " . $c->form->valid('subject'),
			template     => 'email/contact.tt',
			content_type => 'text/html',
		};
		$c->stash->{recipient} = $c->stash->{email}{to};
		
		$c->log->info( "Contact email sent to " . $recipient );
		
		$c->forward( $c->view('Email::Template') );
		
	}
	
	$c->stash->{status_msg} = 'Email sent successfully';
}

=head2 assert_admin

Check that the user is the admin, detaching to a 403 if they aren't.

=cut

sub assert_admin :Private {
	my ( $self, $c, $msg ) = @_;
	
	$msg //= 'You are not the admin.';
	$c->detach('/forbidden', [ $msg ]) unless $c->check_user_roles('admin'); 
}

=head2 strum

Mogrify certain words in the response body.

=cut

my %strum_list = (
	Sturm => 'Strum',
	PavFeira => 'PavFiera',
	PresentPerfect => 'PresentPrefect',
);

sub strum :Private {
	my ( $self, $c ) = @_;
	
	while( my($key, $strum) = each %strum_list ) 
	{
		while( (my $index = CORE::index $c->res->{body}, $key ) > 0 ) 
		{
			substr( $c->res->{body}, $index, length $key ) = $strum;
		}
	}
	
}

=head2 render

Attempt to render a view, if needed.

=cut

sub render : ActionClass('RenderView') {}

sub end :Private {
	my ( $self, $c ) = @_;
	$c->forward('render');
	$c->forward('strum') if $c->config->{strum_ok} && rand > 0.5;
	$c->fillform( $c->stash->{fillform} ) if defined $c->stash->{fillform};
}

=head1 AUTHOR

Cameron Thornton E<lt>cthor@cpan.orgE<gt>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
